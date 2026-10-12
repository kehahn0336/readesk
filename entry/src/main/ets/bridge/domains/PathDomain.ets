/**
 * `plugin:path|*` —— Tauri 路径插件。
 *
 * 数值枚举取自 `@tauri-apps/api` 的编译产物（实测 AppLocalData=15），**不要凭记忆写**：
 *   1 Audio  2 Cache  3 Config  4 Data  5 LocalData  6 Document  7 Download
 *   8 Picture 9 Public 10 Video 11 Resource 12 Temp 13 AppConfig 14 AppData
 *   15 AppLocalData 16 AppCache 17 AppLog 18 Desktop ... 23 Template
 *
 * HarmonyOS 沙箱里没有这些 OS 级目录的真实对应物，因此 1..11 统一落到 `files` 目录，
 * 让相对路径仍然可用；13/14/15/16/17/12 有明确落点。
 */
import { RawJson, argNumber, argString, uriToPath } from '../BridgeProtocol';

export class PathDomain {
  private filesDir: string;
  private cacheDir: string;
  /** 用户自定义书库目录（为空表示用默认 `files/data/Readest`）。 */
  private rootOverride: string = '';

  constructor(filesDir: string, cacheDir: string) {
    this.filesDir = filesDir;
    this.cacheDir = cacheDir;
  }

  setRootOverride(root: string): void {
    this.rootOverride = root;
  }

  rootOverrideValue(): string {
    return this.rootOverride;
  }

  /** 默认书库根目录：上游把 library.json 与书籍都放在 AppData(14)/Readest 下。 */
  defaultLibraryRoot(): string {
    return this.filesDir + '/data/Readest';
  }

  /** libraryRoot 的现值（含覆盖）。 */
  libraryRoot(): string {
    return this.rootOverride.length > 0 ? this.rootOverride : this.defaultLibraryRoot();
  }

  baseRoot(baseDir: number): string {
    switch (baseDir) {
      case 13: return this.filesDir + '/config';   // AppConfig
      case 14:                                     // AppData
      case 15: return this.filesDir + '/data';     // AppLocalData
      case 16: return this.cacheDir;               // AppCache
      case 17: return this.filesDir + '/logs';     // AppLog
      case 12: return this.cacheDir + '/temp';     // Temp
      default:
        if (baseDir >= 1 && baseDir <= 11) return this.filesDir;
        return '';
    }
  }

  /**
   * URI / 绝对路径 → 沙箱物理路径。
   *
   * 自定义书库目录会把默认根下的历史绝对路径重定向到新根，因此已被
   * 持久化的旧路径在换目录后仍然读得到。
   */
  physical(logical: string): string {
    let path = logical;
    const dataShare = 'datashare://';
    const content = 'content://';
    if (path.indexOf('file:') === 0) {
      // 全部写法与百分号解码都交给单一来源（BridgeProtocol.uriToPath）
      path = uriToPath(path);
    } else if (path.indexOf(dataShare) === 0 || path.indexOf(content) === 0) {
      // datashare/content URI 需要经 picker/文件共享转换，这里只取路径部分，
      // 真实导入流程在 M3 的导入域里处理。
      const cut = path.indexOf('/', path.indexOf('://') + 3);
      path = cut > 0 ? path.slice(cut) : path;
    }
    if (this.rootOverride.length > 0) {
      const def = this.defaultLibraryRoot();
      if (path.indexOf(def) === 0) return this.rootOverride + path.slice(def.length);
    }
    return path;
  }

  /** `{ path, options:{ baseDir } }` → 绝对物理路径。 */
  resolve(path: string, options: ESObject): string {
    return this.resolveWithBase(path, options ? argNumber(options, 'baseDir', 0) : 0);
  }

  /**
   * 用**显式** baseDir 解析路径。
   *
   * 需要单独一个入口，是因为 plugin-fs 里有些命令是「每条路径各自一个 baseDir」：
   * `CopyOptions{fromPathBaseDir,toPathBaseDir}`、
   * `RenameOptions{oldPathBaseDir,newPathBaseDir}`。
   * 只认单一 `baseDir` 会把相对路径解析到错的地方 —— 真机实测（2026-09-28）：
   * 浏览器下载入库时 `copy_file` 收到 `options:{toPathBaseDir:14}`，旧实现忽略它，
   * 目标路径落到无权限位置 → `invoke FAIL plugin:fs|copy_file err=Permission denied`。
   */
  resolveWithBase(path: string, baseDir: number): string {
    if (path.length === 0) return path;
    // 注意前缀判断必须覆盖 `file:` 的**全部**写法：真机上出现过
    // `file://docs/…`、`file:///docs/…`、`file:/…`（被 path|join 压掉一个斜杠）。
    // 只认 `file://` 时，`file:/…` 会被当成普通相对路径原样交给 fs → ENOENT
    // （2026-09-30 医生页用例当场抓到：stat 四种写法里第 3 种失败）。
    if (path.indexOf('file:') === 0 || path.indexOf('datashare://') === 0 ||
        path.indexOf('content://') === 0 || path.indexOf('/') === 0) {
      return this.physical(path);
    }
    const root = this.baseRoot(baseDir);
    return root.length > 0 ? root + '/' + path : path;
  }

  /** 便捷版：直接取 `args[key]` 作为路径并解析。 */
  resolveArg(args: ESObject, key: string): string {
    const value: ESObject = args ? args[key] : undefined;
    if (value === undefined || value === null) return '';
    return this.resolve(String(value), args ? args['options'] : undefined);
  }

  /** 分发 `plugin:path|<cmd>`。 */
  handle(cmd: string, args: ESObject): ESObject {
    switch (cmd) {
      case 'resolve_directory': {
        // 上游每次启动都问 `AppData(14) + Readest`，这是自定义书库目录能生效的钩子。
        const directory = argNumber(args, 'directory', 0);
        const root = this.baseRoot(directory);
        if (root.length === 0) throw new Error('unsupported base directory: ' + directory);
        const sub = argString(args, 'path');
        return new RawJson(JSON.stringify(sub.length > 0 ? root + '/' + sub : root));
      }
      case 'join':
        return new RawJson(JSON.stringify(PathDomain.joinAll(PathDomain.pathList(args))));
      case 'resolve': {
        const parts = PathDomain.pathList(args);
        if (parts.length === 0) return new RawJson('""');
        let acc = PathDomain.isAbsolute(parts[0]) ? parts[0] : this.filesDir + '/' + parts[0];
        for (let i = 1; i < parts.length; i++) {
          acc = PathDomain.isAbsolute(parts[i]) ? parts[i] : acc + '/' + parts[i];
        }
        return new RawJson(JSON.stringify(PathDomain.normalize(acc)));
      }
      case 'normalize':
        return new RawJson(JSON.stringify(PathDomain.normalize(argString(args, 'path'))));
      case 'basename':
        return new RawJson(JSON.stringify(PathDomain.basename(argString(args, 'path'))));
      case 'dirname':
        return new RawJson(JSON.stringify(PathDomain.dirname(argString(args, 'path'))));
      case 'extname':
        return new RawJson(JSON.stringify(PathDomain.extname(argString(args, 'path'))));
      case 'is_absolute':
        return PathDomain.isAbsolute(argString(args, 'path'));
      default:
        throw new Error('unsupported bridge command: plugin:path|' + cmd);
    }
  }

  private static pathList(args: ESObject): Array<string> {
    const out: Array<string> = [];
    const paths: ESObject = args ? args['paths'] : undefined;
    if (paths instanceof Array) {
      // ArkTS 不允许 Array<any/unknown>，路径数组按字符串读。
      const arr = paths as Array<string>;
      for (let i = 0; i < arr.length; i++) out.push(String(arr[i]));
    }
    const single: ESObject = args ? args['path'] : undefined;
    if (single !== undefined && single !== null) out.push(String(single));
    return out;
  }

  static isAbsolute(path: string): boolean {
    if (path.length === 0) return false;
    const first = path.charAt(0);
    if (first === '/' || first === '\\') return true;
    // 带 scheme 的 URI（`file://…`、`content://…`）也是"绝对"的。
    // 不认的话 normalize 会把它当相对路径处理 —— 见下面对 URI 的专门分支。
    if (path.indexOf('://') > 0) return true;
    if (path.indexOf('file:/') === 0) return true;
    return false;
  }

  /** POSIX 风格归一化：折叠 `.`、`..` 与重复斜杠（不做符号链接解析）。 */
  static normalize(path: string): string {
    if (path.length === 0) return '.';
    // URI 必须**保形**：只规范化 scheme://authority 之后的路径部分。
    // 旧实现按 '/' 切分后丢掉空段，会把 `file://docs/x` 压成 `file:/docs/x`；
    // 而应用判断"是不是 URI"用的是 `startsWith('file://')`（utils/misc.isFileURI），
    // 一旦被压成单斜杠，它就不再走"经选择器授权复制进 cache"的那条路，
    // 改成按真实路径直读 —— 用户空间的文件没有授权，会 EPERM。
    // 真机证据（2026-09-30）：文件夹导入里 join 出来的路径就是 `file:/docs/…`。
    const schemeCut = path.indexOf('://');
    if (schemeCut > 0) {
      const scheme = path.slice(0, schemeCut + 3);
      const rest = path.slice(schemeCut + 3);
      const slash = rest.indexOf('/');
      if (slash < 0) return scheme + rest;
      return scheme + rest.slice(0, slash) + PathDomain.normalize(rest.slice(slash));
    }
    const absolute = PathDomain.isAbsolute(path);
    const parts = path.split('/');
    const stack: Array<string> = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (part.length === 0 || part === '.') continue;
      if (part === '..') {
        if (stack.length > 0 && stack[stack.length - 1] !== '..') stack.pop();
        else if (!absolute) stack.push('..');
        continue;
      }
      stack.push(part);
    }
    const body = stack.join('/');
    if (absolute) return body.length > 0 ? '/' + body : '/';
    return body.length > 0 ? body : '.';
  }

  static joinAll(parts: Array<string>): string {
    const kept: Array<string> = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) kept.push(parts[i]);
    }
    if (kept.length === 0) return '';
    return PathDomain.normalize(kept.join('/'));
  }

  static basename(path: string): string {
    const trimmed = path.length > 1 && path.charAt(path.length - 1) === '/'
      ? path.slice(0, path.length - 1) : path;
    const cut = trimmed.lastIndexOf('/');
    return cut >= 0 ? trimmed.slice(cut + 1) : trimmed;
  }

  static dirname(path: string): string {
    if (path.indexOf('/') < 0) return '.';
    const cut = path.lastIndexOf('/');
    if (cut === 0) return '/';
    return path.slice(0, cut);
  }

  static extname(path: string): string {
    const base = PathDomain.basename(path);
    const dot = base.lastIndexOf('.');
    return dot > 0 ? base.slice(dot) : '';
  }
}
