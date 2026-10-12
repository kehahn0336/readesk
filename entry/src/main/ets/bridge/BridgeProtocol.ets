/**
 * 桥的线上协议（wire protocol）。
 *
 * 这些约定由 JS 侧 `readest-bridge.js` 的 encode()/decode() 唯一决定，改这里必须同步改那边：
 *
 *   请求  invoke(cmd, JSON.stringify(encode(args)))
 *         - Uint8Array / ArrayBuffer 折成 { __readestUint8: base64 }
 *         - 带 headers 时整体包一层 { __readestArgs: <encoded>, __readestHeaders: {...} }
 *   响应  { ok: true, data } | { ok: false, error }
 *         - 字节结果用 { __readestBytes: base64 } 返回，JS 侧 decode() 会还原成 Uint8Array
 *   异步  invokeAsync(cmd, argsJson, callbackId)
 *         原生稍后回调 window.__READEST_BRIDGE__.resolve(callbackId, dataJson) / .reject(...)
 */
import { util } from '@kit.ArkTS';

export interface SizedBytes {
  bytes: Uint8Array;
  size: number;
}

export interface DirEntryJson {
  name: string;
  isFile: boolean;
  isDirectory: boolean;
  isSymlink: boolean;
}

/** 与 @tauri-apps/plugin-fs 的 FileInfo 对齐（mtime 等为毫秒，JS 侧会 new Date(...)）。 */
export interface FileInfoJson {
  isFile: boolean;
  isDirectory: boolean;
  isSymlink: boolean;
  size: number;
  mtime: number | null;
  atime: number | null;
  birthtime: number | null;
  readonly: boolean;
}

/**
 * 已序列化好的 JSON 片段。
 *
 * ArkTS 不允许无类型对象字面量，而 `{ __readestBytes: ... }` 这类动态键的载荷
 * 又没法用 interface 优雅表达（键名由 JS 侧写死）。用字符串拼接最直接也最快，
 * 并借本类把"这段已经是 JSON"这一事实显式传给传输层。
 */
export class RawJson {
  json: string;

  constructor(json: string) {
    this.json = json;
  }
}

const base64: util.Base64Helper = new util.Base64Helper();

export function toBase64(bytes: Uint8Array): string {
  // 与 fromBase64 同理：0 字节是合法输入（备份里就有空文件），
  // 不能让 `encodeToStringSync` 因空内容抛错。
  if (bytes.length === 0) return '';
  return base64.encodeToStringSync(bytes);
}

export function fromBase64(text: string): Uint8Array {
  // ⚠️ **空串是合法输入**，不能直接交给系统：HarmonyOS 的
  //    Base64Helper.decodeSync('') 会抛
  //      "Parameter error. The type of Parameter must be string and the length greater than 0."
  // 2026-10-10 「备份书库 → 保存失败」的真根因就在这：上游备份回退路径的第一步是
  // `writeFile(path, new Uint8Array())` —— **写 0 字节做截断** —— 而它必然经过这里。
  if (text.length === 0) return new Uint8Array(0);
  return base64.decodeSync(text);
}

/** 字节结果：JS 侧 decode() 见 __readestBytes 即还原为 Uint8Array。 */
export function bytesResultJson(bytes: Uint8Array): RawJson {
  return new RawJson('{"__readestBytes":"' + toBase64(bytes) + '"}');
}

/** 取字节载荷：线上一定是 { __readestUint8: base64 }，但也容忍已经解码的形态。 */
export function payloadBytes(value: ESObject): Uint8Array | undefined {
  if (value === undefined || value === null) return undefined;
  if (value instanceof Uint8Array) return value as Uint8Array;
  if (value instanceof ArrayBuffer) return new Uint8Array(value as ArrayBuffer);
  const encoded: ESObject = value['__readestUint8'];
  if (typeof encoded === 'string') return fromBase64(encoded as string);
  return undefined;
}

/** 剥掉 { __readestArgs, __readestHeaders } 包装，拿到真正的参数袋。 */
export function wireArgs(args: ESObject): ESObject {
  if (args === undefined || args === null) return {};
  const inner: ESObject = args['__readestArgs'];
  if (inner !== undefined && inner !== null) return inner;
  return args;
}

/** 剥出的 headers（没有则 undefined）。 */
export function wireHeaders(args: ESObject): ESObject | undefined {
  if (args === undefined || args === null) return undefined;
  const headers: ESObject = args['__readestHeaders'];
  if (headers === undefined || headers === null) return undefined;
  return headers;
}

export function argString(args: ESObject, key: string): string {
  const value: ESObject = args ? args[key] : undefined;
  return value === undefined || value === null ? '' : String(value);
}

export function argNumber(args: ESObject, key: string, fallback: number): number {
  const value: ESObject = args ? args[key] : undefined;
  if (value === undefined || value === null) return fallback;
  const n = Number(value);
  return isNaN(n) ? fallback : n;
}

export function argBool(args: ESObject, key: string, fallback: boolean): boolean {
  const value: ESObject = args ? args[key] : undefined;
  return value === undefined || value === null ? fallback : value === true;
}

export function argObject(args: ESObject, key: string): ESObject {
  const value: ESObject = args ? args[key] : undefined;
  if (value === undefined || value === null) return {};
  return value;
}

/**
 * 把字符串编成 UTF-8 字节，并**只**返回真正写进去的长度。
 *
 * 必须用 encodeIntoUint8Array：编码器返回的 buffer 会按 `text.length * 3` 预留，
 * 若把整块 buffer 写进文件，尾部会留下零填充（实测 13 字符的文本读回来 39 字节）。
 * 同理不能用 `encodeInto(text)`，它在设备上返回 undefined。
 */
export function encodeUtf8Sized(text: string): SizedBytes {
  const dest = new Uint8Array(text.length * 3 + 3);
  const result: SizedBytes = { bytes: dest, size: 0 };
  if (text.length === 0) return result;
  const info = util.TextEncoder.create('utf-8').encodeIntoUint8Array(text, dest);
  result.size = info.written;
  return result;
}

/** 8 字节大端 u64 —— plugin:fs|read 要求把 nread 附在数据末尾就是这个编码。 */
export function u64BigEndian(value: number): Uint8Array {
  const out = new Uint8Array(8);
  let rest = value;
  for (let i = 7; i >= 0; i--) {
    out[i] = rest & 0xff;
    rest = Math.floor(rest / 256);
  }
  return out;
}

/** 拼接两段字节。 */
export function concatBytes(head: Uint8Array, tail: Uint8Array): Uint8Array {
  const out = new Uint8Array(head.length + tail.length);
  out.set(head, 0);
  out.set(tail, head.length);
  return out;
}

/** 取数组缓冲区的一段，专供 writeSync(fd, ArrayBuffer) 使用。 */
export function exactBuffer(bytes: Uint8Array, size: number): ArrayBuffer {
  return bytes.buffer.slice(0, size) as ArrayBuffer;
}

/**
 * `file:` URI → 真实路径。**纯函数，单一来源**。
 *
 * 真机上 file URI 出现过**四种**写法（都是系统/应用给的）：
 *   file://docs/storage/…      docs 是 authority（选择器原始形态）
 *   file:///docs/storage/…     authority 为空，docs 落到路径首段
 *   file:/docs/storage/…       被应用侧 path|join 压掉一个斜杠后的形态
 *   file:///storage/…          没有 docs 段
 * 而且路径部分是**百分号编码**的（中文目录 → `%E6%B5%8B%E8%AF%95`）。
 *
 * 为什么必须单一来源（2026-10-03 的教训）：`PathDomain.physical()` 和
 * `LegacyBridge.uriToPhysical()` 曾是**两份各自实现** —— 前者加了百分号解码、
 * 后者没加，于是"目录对话框回可读路径"的判定一直 ENOENT、界面始终显示编码后的 URI。
 * 与旧工程"两份 readest-bridge.js 只改一份"是同一类错误。
 */
export function uriToPath(value: string): string {
  if (value.indexOf('file:') !== 0) return value;
  let rest = value.slice('file:'.length);
  rest = rest.replace(/^\/+/, '/');
  if (rest.indexOf('/docs/') === 0) rest = rest.slice('/docs'.length);
  try {
    rest = decodeURIComponent(rest);
  } catch (_error) {
    // 含非法转义（例如真实文件名里就有 %）时保持原样
  }
  return rest;
}
