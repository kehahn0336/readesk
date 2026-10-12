/**
 * `plugin:fs|*` —— Tauri 文件系统插件。
 *
 * 契约取自 `@tauri-apps/plugin-fs@2.5.2` 的 JS 源码（权威），三处容易写错：
 *  1. `read_file` / `read_text_file` 都返回**字节**（JS 侧自己 Uint8Array.from / TextDecoder）。
 *  2. `plugin:fs|read` 要求返回 `数据 ++ 8 字节大端 nread`，JS 侧 `data.slice(-8)` 取计数；
 *     且 nread=0 表示 EOF（JS 会返回 null）。
 *  3. `stat` 的 `mtime/atime` 必须是**毫秒**（JS 侧 `new Date(r.mtime)`），
 *     而 HarmonyOS `Stat.mtime` 的单位是**秒**。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { PathDomain } from './PathDomain';
import {
  DirEntryJson,
  FileInfoJson,
  RawJson,
  argBool,
  argNumber,
  argString,
  bytesResultJson,
  concatBytes,
  exactBuffer,
  encodeUtf8Sized,
  payloadBytes,
  u64BigEndian,
  wireArgs,
  wireHeaders,
} from '../BridgeProtocol';

/** whence 取值，与 HarmonyOS WhenceType 一致。 */
const SEEK_SET = 0;
const SEEK_CUR = 1;
const SEEK_END = 2;

const CHUNK = 1 << 20;

class OpenFile {
  fd: number;

  constructor(fd: number) {
    this.fd = fd;
  }
}

/** 原生命令 `read_dir` 的返回条目：路径（按入参形态拼前缀）+ 字节大小。 */
class ScannedFileJson {
  path: string;
  size: number;

  constructor(path: string, size: number) {
    this.path = path;
    this.size = size;
  }
}

/** `read_dir` 的遍历节点：绝对路径（用于列举）+ 相对扫描根的相对路径（用于拼返回前缀）。 */
class ScanNode {
  dir: string;
  rel: string;

  constructor(dir: string, rel: string) {
    this.dir = dir;
    this.rel = rel;
  }
}

export class FsDomain {

  /**
   * 稳健复制：`fromPath` 在真机上常常不是普通路径，而是
   * **`file://` URI（中文目录还会被百分号编码）** —— 例如
   *   `file://docs/<用户目录>/Documents/%E6%B5%8B%E8%AF%95/a.epub`
   *   （`%E6%B5%8B%E8%AF%95` 即中文目录「测试」被百分号编码后的样子）
   * 而 `fs.copyFileSync` 既不认 URI、也不认编码后的路径，会直接 ENOENT
   * （2026-09-29 真机证据：文件夹导入因此失败；单文件只是靠前端回退掩盖了）。
   *
   * 所以按候选逐个尝试：
   *   ① 解析后的真实路径（`physical()` 已对 URI 做百分号解码）
   *   ② 原始形态（URI 原样）—— `fs.openSync` 是**认 URI** 的，与
   *      `copy_uri_to_path` 里已验证可行的做法一致
   * 先试 `copyFileSync`，全失败再退化为"打开源 → 逐字节写"。
   */
  private copyWithFallback(pathForm: string, rawForm: string, to: string): void {
    const candidates: Array<string> = [pathForm, rawForm];
    let lastError = '';
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length === 0) continue;
      try {
        fs.copyFileSync(candidates[i], to);
        return;
      } catch (error) {
        lastError = String(error);
      }
    }
    let src: fs.File | undefined = undefined;
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length === 0) continue;
      try {
        src = fs.openSync(candidates[i], fs.OpenMode.READ_ONLY);
        break;
      } catch (error) {
        lastError = String(error);
      }
    }
    if (src === undefined) {
      throw new Error('copy failed, cannot open source: ' + lastError);
    }
    const out = fs.openSync(to, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let copied = 0;
    try {
      const size = fs.statSync(src.fd).size;
      const buffer = new ArrayBuffer(size);
      const read = fs.readSync(src.fd, buffer, { offset: 0 });
      if (read > 0) {
        fs.writeSync(out.fd, buffer.slice(0, read));
        copied = read;
      }
    } finally {
      fs.closeSync(src.fd);
      fs.closeSync(out.fd);
    }
    this.onDiag('copy_file via byte-copy bytes=' + String(copied) + ' from=' + rawForm);
  }

  private paths: PathDomain;
  private onDiag: (message: string) => void = (_message: string) => {};
  private open: Map<number, OpenFile> = new Map();
  private nextRid: number = 1;

  constructor(paths: PathDomain) {
    this.paths = paths;
  }

  /** 诊断回调（由 ReadestBridge 注入）。 */
  setDiagSink(sink: (message: string) => void): void {
    this.onDiag = sink;
  }

  /** 释放所有句柄（页面销毁时调用，避免 fd 泄漏）。 */
  closeAll(): void {
    this.open.forEach((file: OpenFile) => {
      try {
        fs.closeSync(file.fd);
      } catch (_error) {
      }
    });
    this.open.clear();
  }

  handle(cmd: string, rawArgs: ESObject): ESObject {
    // 写命令要连信封一起看（正文在 __readestArgs、path/options 在 __readestHeaders）；
    // 其余命令只看正文。
    const isWrite = cmd === 'write_text_file' || cmd === 'write_file';
    const args: ESObject = isWrite
      ? ((rawArgs === undefined || rawArgs === null) ? {} : rawArgs)
      : wireArgs(rawArgs);
    switch (cmd) {
      case 'exists': {
        const path = this.paths.resolveArg(args, 'path');
        return fs.accessSync(path, fs.AccessModeType.EXIST);
      }
      case 'read_text_file':
      case 'read_file': {
        const path = this.paths.resolveArg(args, 'path');
        return bytesResultJson(this.readAllBytes(path));
      }
      // 两类写命令的线上形态（Tauri plugin-fs → shim）：
      //   { __readestArgs: {__readestUint8: <base64 正文>},
      //     __readestHeaders: {path: <encodeURIComponent>, options: <JSON 串>} }
      // 只取正文（丢掉 headers）会让 path 变成空串，设备上表现为
      // "Open failed, path is: " —— settings.json 永远存不下去。
      case 'write_text_file': {
        const path = this.writeTarget(args);
        const body = this.writeBody(args);
        if (body !== undefined) {
          this.writeBytes(path, body, body.length);
        } else {
          const sized = encodeUtf8Sized(argString(args, 'data'));
          this.writeBytes(path, sized.bytes, sized.size);
        }
        return null;
      }
      case 'write_file': {
        const path = this.writeTarget(args);
        const bytes = this.writeBody(args);
        if (bytes === undefined) throw new Error('write_file: missing byte payload');
        this.writeBytes(path, bytes, bytes.length);
        return null;
      }
      case 'create': {
        const path = this.paths.resolveArg(args, 'path');
        this.ensureParent(path);
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        fs.closeSync(file.fd);
        return null;
      }
      case 'mkdir': {
        const path = this.paths.resolveArg(args, 'path');
        const options: ESObject = args ? args['options'] : undefined;
        const recursive = options ? argBool(options, 'recursive', false) : false;
        this.makeDir(path, recursive);
        return null;
      }
      case 'remove': {
        const path = this.paths.resolveArg(args, 'path');
        const options: ESObject = args ? args['options'] : undefined;
        const recursive = options ? argBool(options, 'recursive', false) : false;
        this.removePath(path, recursive);
        return null;
      }
      case 'stat':
        return this.statJson(this.paths.resolveArg(args, 'path'), true);
      case 'lstat':
        return this.statJson(this.paths.resolveArg(args, 'path'), false);
      case 'size': {
        const path = this.paths.resolveArg(args, 'path');
        return fs.statSync(path).size;
      }
      case 'read_dir': {
        const path = this.paths.resolveArg(args, 'path');
        const names = fs.listFileSync(path);
        const entries: Array<DirEntryJson> = [];
        for (let i = 0; i < names.length; i++) {
          const child = path + '/' + names[i];
          const st = fs.lstatSync(child);
          const entry: DirEntryJson = {
            name: names[i],
            isFile: st.isFile(),
            isDirectory: st.isDirectory(),
            isSymlink: st.isSymbolicLink(),
          };
          entries.push(entry);
        }
        return entries;
      }
      case 'open':
        return this.openFile(args);
      case 'read':
        return this.readFd(args);
      case 'write':
        return this.writeFd(args);
      case 'seek':
        return this.seekFd(args);
      case 'fstat': {
        const file = this.fileOf(args);
        return this.statOf(fs.statSync(file.fd));
      }
      case 'ftruncate': {
        const file = this.fileOf(args);
        fs.truncateSync(file.fd, argNumber(args, 'len', 0));
        return null;
      }
      case 'truncate': {
        const path = this.paths.resolveArg(args, 'path');
        fs.truncateSync(path, argNumber(args, 'len', 0));
        return null;
      }
      case 'close': {
        const file = this.fileOf(args);
        fs.closeSync(file.fd);
        this.open.delete(this.ridOf(args));
        return null;
      }
      case 'copy_file': {
        // plugin-fs 的 CopyOptions 是**每路径各自**的 baseDir 字段
        // （fromPathBaseDir / toPathBaseDir），不是单一 baseDir。
        const opts: ESObject = args ? args['options'] : undefined;
        const fromRaw = String(args['fromPath']);
        const fromBase = opts ? argNumber(opts, 'fromPathBaseDir', 0) : 0;
        const to = this.paths.resolveWithBase(String(args['toPath']),
          opts ? argNumber(opts, 'toPathBaseDir', 0) : 0);
        this.ensureParent(to);
        // 源可能是 `file://docs/…` URI（中文目录还是百分号编码）→ 见 copyWithFallback
        this.copyWithFallback(this.paths.resolveWithBase(fromRaw, fromBase), fromRaw, to);
        return null;
      }
      case 'rename': {
        // RenameOptions{oldPathBaseDir,newPathBaseDir}，同上。
        const opts: ESObject = args ? args['options'] : undefined;
        const oldRaw = String(args['oldPath']);
        const oldBase = opts ? argNumber(opts, 'oldPathBaseDir', 0) : 0;
        const newPath = this.paths.resolveWithBase(String(args['newPath']),
          opts ? argNumber(opts, 'newPathBaseDir', 0) : 0);
        this.ensureParent(newPath);
        const oldPath = this.paths.resolveWithBase(oldRaw, oldBase);
        try {
          fs.moveFileSync(oldPath, newPath);
        } catch (error) {
          // URI 源同样可能不被 moveFileSync 接受：退化为"复制 + 删源"（即 move 语义）。
          this.copyWithFallback(oldPath, oldRaw, newPath);
          try {
            fs.unlinkSync(oldPath);
          } catch (_unlinkError) {
          }
        }
        return null;
      }
      default:
        throw new Error('unsupported bridge command: plugin:fs|' + cmd);
    }
  }

  /**
   * 原生命令 `read_dir`（**不带 `plugin:` 前缀**）—— 上游用 Rust `WalkDir` 做的
   * 目录扫描，是"从文件夹导入"的热路径。
   *
   * 契约（`nativeAppService.readDir`）：
   *   invoke('read_dir', { path, recursive: true, extensions: ['epub','pdf'] })
   *     → [{ path, size }]
   * 其中 **`path` 必须以传入的 `path` 形态为前缀** —— 应用是这么算相对路径的：
   *   const getRelativePath = (filePath, basePath) =>
   *     filePath.startsWith(basePath) ? filePath.slice(basePath.length) : filePath
   * 上游桌面端传的是真实路径，所以 Rust 回绝对路径就能对上；而**鸿蒙的选择器给的是
   * URI**（`file://docs/…`，中文还是百分号编码），此时若回真实绝对路径，
   * `startsWith` 不成立 → 相对路径退化成"绝对路径去掉开头斜杠" →
   * 应用拼出 `{URI}/{绝对路径}` 这种垃圾路径（2026-09-30 真机复现）。
   * 所以这里**按入参形态拼前缀**。
   *
   * 真机证据：没实现时 `invoke FAIL read_dir err=unsupported bridge command`，
   * 应用退到 JS 递归回退，而回退里 `join` 出的路径被压成 `file:/docs/…` → `stat` 全 ENOENT
   * → 文件夹导入失败。补齐它即走回快路径。
   */
  readDirectoryTree(pathArg: string, extensions: Array<string>, recursive: boolean): ESObject {
    const root = this.paths.resolveWithBase(pathArg, 0);
    const prefix = pathArg.replace(/\/+$/, '');
    const exts = new Set<string>();
    let matchAll = false;
    for (let i = 0; i < extensions.length; i++) {
      const ext = String(extensions[i]).toLowerCase().replace(/^\./, '');
      if (ext === '*') matchAll = true;
      else if (ext.length > 0) exts.add(ext);
    }
    const found: Array<ScannedFileJson> = [];
    const stack: Array<ScanNode> = [new ScanNode(root, '')];
    while (stack.length > 0) {
      const node = stack.pop() as ScanNode;
      let names: Array<string> = [];
      try {
        names = fs.listFileSync(node.dir);
      } catch (_error) {
        continue; // 读不到的目录直接跳过（与 Rust 侧宽容语义一致）
      }
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        const full = node.dir + '/' + name;
        const rel = node.rel.length === 0 ? name : node.rel + '/' + name;
        try {
          const info = fs.statSync(full);
          if (info.isDirectory()) {
            if (recursive) stack.push(new ScanNode(full, rel));
            continue;
          }
          if (!matchAll) {
            const dot = name.lastIndexOf('.');
            const ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : '';
            if (!exts.has(ext)) continue;
          }
          found.push(new ScannedFileJson(prefix.length > 0 ? prefix + '/' + rel : rel, info.size));
        } catch (_error) {
          // 条目在读的过程中消失/无权限：跳过，不影响整次扫描
        }
      }
    }
    this.onDiag('read_dir walked=' + pathArg + ' matched=' + String(found.length));
    return found;
  }

  // ── 文件句柄 ─────────────────────────────────────────────────────────

  private openFile(args: ESObject): ESObject {
    const path = this.paths.resolveArg(args, 'path');
    const options: ESObject = args ? args['options'] : undefined;
    const wantRead = options ? argBool(options, 'read', false) : false;
    const wantWrite = options ? argBool(options, 'write', false) : false;
    const wantAppend = options ? argBool(options, 'append', false) : false;
    const wantTruncate = options ? argBool(options, 'truncate', false) : false;
    const wantCreate = options ? argBool(options, 'create', false) : false;
    const createNew = options ? argBool(options, 'createNew', false) : false;

    if (createNew && fs.accessSync(path, fs.AccessModeType.EXIST)) {
      throw new Error('file already exists: ' + path);
    }
    let mode = fs.OpenMode.READ_ONLY;
    if (wantRead && wantWrite) mode = fs.OpenMode.READ_WRITE;
    else if (wantWrite) mode = fs.OpenMode.WRITE_ONLY;
    if (wantAppend) mode = mode | fs.OpenMode.APPEND;
    if (wantTruncate) mode = mode | fs.OpenMode.TRUNC;
    if (wantCreate || createNew) mode = mode | fs.OpenMode.CREATE;
    this.ensureParent(path);

    const file = fs.openSync(path, mode);
    const rid = this.nextRid++;
    this.open.set(rid, new OpenFile(file.fd));
    return rid;
  }

  /**
   * 按 rid 释放文件句柄（供 Tauri 的 **core** 命令 `plugin:resources|close` 使用）。
   *
   * 2026-10-11 真机暴露：备份回退路径（zip.js 关流）会调 `plugin:resources|close`，
   * 而我们没实现 → 整个备份以 `unsupported bridge command: plugin:resources|close` 失败。
   * 在本移植里 rid 就是本域分配的句柄编号 → 释放它即可。
   * 返回是否真的释放了句柄；**找不到不抛错**（基类 close 的语义是尽力释放，
   * 且该 rid 也可能属于别的资源类型）。
   */
  closeRid(rid: number): boolean {
    const file = this.open.get(rid);
    if (file === undefined) return false;
    try {
      fs.closeSync(file.fd);
    } catch (error) {
      this.onDiag('closeRid fs.closeSync failed: ' + String(error));
    }
    this.open.delete(rid);
    return true;
  }

  private ridOf(args: ESObject): number {
    return argNumber(args, 'rid', -1);
  }

  private fileOf(args: ESObject): OpenFile {
    const rid = this.ridOf(args);
    const file = this.open.get(rid);
    if (file === undefined) throw new Error('invalid file handle: ' + rid);
    return file;
  }

  /** 返回 `数据 ++ 8 字节大端 nread`。 */
  private readFd(args: ESObject): ESObject {
    const file = this.fileOf(args);
    const len = argNumber(args, 'len', 0);
    if (len <= 0) return bytesResultJson(u64BigEndian(0));
    const buffer = new ArrayBuffer(len);
    const read = fs.readSync(file.fd, buffer);
    const count = read > 0 ? read : 0;
    const payload = new Uint8Array(buffer, 0, count);
    return bytesResultJson(concatBytes(payload, u64BigEndian(count)));
  }

  private writeFd(args: ESObject): ESObject {
    const file = this.fileOf(args);
    const bytes = payloadBytes(args ? args['data'] : undefined);
    if (bytes === undefined) return 0;
    if (bytes.length === 0) return 0;
    return fs.writeSync(file.fd, exactBuffer(bytes, bytes.length));
  }

  private seekFd(args: ESObject): ESObject {
    const file = this.fileOf(args);
    const offset = argNumber(args, 'offset', 0);
    let whence = argNumber(args, 'whence', SEEK_SET);
    if (whence !== SEEK_SET && whence !== SEEK_CUR && whence !== SEEK_END) whence = SEEK_SET;
    return fs.lseek(file.fd, offset, whence);
  }

  // ── 基础实现 ─────────────────────────────────────────────────────────

  private readAllBytes(path: string): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      this.onDiag('readAllBytes ' + path + ' size=' + size);
      if (size <= 0) return new Uint8Array(0);
      const out = new Uint8Array(size);
      let total = 0;
      while (total < size) {
        const want = Math.min(size - total, CHUNK);
        const buffer = new ArrayBuffer(want);
        const read = fs.readSync(file.fd, buffer);
        if (read <= 0) break;
        out.set(new Uint8Array(buffer, 0, read), total);
        total += read;
      }
      return total === size ? out : out.slice(0, total);
    } finally {
      fs.closeSync(file.fd);
    }
  }

  /** 只写入真正有效的字节：整块 buffer 写进去会在尾部留零填充。 */
  private writeBytes(path: string, bytes: Uint8Array, size: number): void {
    if (path.length === 0) {
      this.onDiag('fsWrite ABORT: empty path (size=' + String(size) + ')');
      throw new Error('writeBytes: empty path');
    }
    try {
      this.ensureParent(path);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        if (size > 0) fs.writeSync(file.fd, exactBuffer(bytes, size));
      } finally {
        fs.closeSync(file.fd);
      }
      this.onDiag('fsWrite ok: size=' + String(size) + ' path=' + path.slice(0, 120));
    } catch (error) {
      this.onDiag('fsWrite FAILED: size=' + String(size) + ' path=' + path.slice(0, 120) +
        ' err=' + String(error));
      throw error as Error;
    }
  }

  /** 写命令的正文：先看 `__readestArgs` 里的字节袋，再兼容直连形态 `{ path, data }`。 */
  private writeBody(args: ESObject): Uint8Array | undefined {
    const fromPayload = payloadBytes(wireArgs(args));
    if (fromPayload !== undefined) return fromPayload;
    return payloadBytes(args ? args['data'] : undefined);
  }

  /** 写命令的落地路径：优先用 `__readestHeaders` 里的 path/options。 */
  private writeTarget(args: ESObject): string {
    const headers: ESObject = wireHeaders(args);
    if (headers === undefined) return this.paths.resolveArg(args, 'path');
    const rawPath: ESObject = headers['path'];
    const logical: string =
      (rawPath === undefined || rawPath === null) ? '' : decodeURIComponent(String(rawPath));
    let options: ESObject = {};
    const rawOptions: ESObject = headers['options'];
    if (rawOptions !== undefined && rawOptions !== null) {
      try {
        options = JSON.parse(String(rawOptions));
      } catch (_error) {
        options = {};
      }
    }
    const resolved = this.paths.resolve(logical, options);
    // 2026-10-10 排查「备份书库→保存失败」：应用回退路径会往**用户空间 URI**
    // （file://docs/<用户目录>/…）写，若解析出空串，原生 API 会回
    // "The type of Parameter must be string and the length greater than 0"。
    // 这里把三个形态都记下来，一眼可判断是解码、解析还是落盘的问题。
    this.onDiag('fsWrite target: raw=' + String(rawPath).slice(0, 120) +
      ' | logical=' + logical.slice(0, 120) + ' | resolved=' + resolved.slice(0, 120));
    return resolved;
  }

  private ensureParent(path: string): void {
    const slash = path.lastIndexOf('/');
    if (slash <= 0) return;
    this.makeDir(path.slice(0, slash), true);
  }

  private makeDir(path: string, recursive: boolean): void {
    if (path.length === 0) return;
    if (fs.accessSync(path, fs.AccessModeType.EXIST)) {
      // mkdir -p 语义：目录已存在不算错误，但非递归的 mkdir 必须报错。
      if (!recursive) throw new Error('directory already exists: ' + path);
      return;
    }
    if (recursive) {
      const slash = path.lastIndexOf('/');
      if (slash > 0) this.makeDir(path.slice(0, slash), true);
    }
    try {
      fs.mkdirSync(path);
    } catch (error) {
      if (!fs.accessSync(path, fs.AccessModeType.EXIST)) throw error as Error;
    }
  }

  private removePath(path: string, recursive: boolean): void {
    // 路径不存在时是**幂等 no-op**（与旧实现及上游预期一致）：应用启动时就会
    // `remove('search', { baseDir: AppCache, recursive: true })` 清索引缓存，
    // 而该目录常常从未创建过；在这里报错只会污染日志、误导排障。
    let st: fs.Stat;
    try {
      st = fs.lstatSync(path);
    } catch (_error) {
      return;
    }
    if (!st.isDirectory()) {
      fs.unlinkSync(path);
      return;
    }
    const names = fs.listFileSync(path);
    if (names.length > 0 && !recursive) {
      throw new Error('directory not empty: ' + path);
    }
    for (let i = 0; i < names.length; i++) {
      this.removePath(path + '/' + names[i], recursive);
    }
    fs.rmdirSync(path);
  }

  private statJson(path: string, follow: boolean): ESObject {
    const st = follow ? fs.statSync(path) : fs.lstatSync(path);
    this.onDiag('stat ' + path + ' size=' + st.size + ' file=' + st.isFile());
    return this.statOf(st);
  }

  private statOf(st: fs.Stat): ESObject {
    const info: FileInfoJson = {
      isFile: st.isFile(),
      isDirectory: st.isDirectory(),
      isSymlink: st.isSymbolicLink(),
      size: st.size,
      // HarmonyOS 的秒 → Tauri 期望的毫秒。
      mtime: st.mtime * 1000,
      atime: st.atime * 1000,
      birthtime: null,
      readonly: false,
    };
    return info;
  }
}
