/**
 * 桥的传输层与路由。
 *
 * 分层（M3 迁移期）：
 *   ReadestBridge（本文件）  传输 + 路由 + 诊断 + 对外门面
 *     ├─ domains/PathDomain    plugin:path|*   ← 已按契约重写并真机验证
 *     ├─ domains/FsDomain      plugin:fs|*     ← 已按契约重写并真机验证
 *     ├─ domains/WindowDomain  plugin:window|* ← 已按契约重写并真机验证
 *     └─ legacy/LegacyBridge   其余域（app/event/turso/http/ws/tts/browser/...）
 *
 * 迁移纪律：新域**先**在这里拦截，命中的命令不会进 LegacyBridge；因此旧实现里
 * 对应的 fs/path/window 代码是暂时不可达的对照物，等各域在真实应用里跑通后逐个删除。
 * 新增功能一律进 `domains/`，不要写进 LegacyBridge。
 */
import { common } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RawJson, argNumber, encodeUtf8Sized, exactBuffer, wireArgs } from './BridgeProtocol';
import { PathDomain } from './domains/PathDomain';
import { FsDomain } from './domains/FsDomain';
import { WindowDomain } from './domains/WindowDomain';
import { LegacyBridge } from './legacy/LegacyBridge';

const DOMAIN = 0x5246;
const TAG = 'ReadestBridge';

const FS_PREFIX = 'plugin:fs|';
const PATH_PREFIX = 'plugin:path|';
const WINDOW_PREFIX = 'plugin:window|';

/** 已迁移到新域的前缀（这些命令不会再进 LegacyBridge）。 */
const MIGRATED_PREFIXES: Array<string> = [FS_PREFIX, PATH_PREFIX, WINDOW_PREFIX];

export class ReadestBridge {
  private context: common.UIAbilityContext | undefined = undefined;
  private deviceFormLogged: boolean = false;
  /**
   * 顶部避让高度的**稳定值**（vp）。
   *
   * 为什么必须缓存：系统栏**隐藏**时 `getWindowAvoidArea(TYPE_SYSTEM)` 会塌成 0
   * （真机实测：同一次运行里先 44 后 0）。而网页只在挂载时取一次并**长期使用**，
   * 若正好取到 0，菜单出现时就不会撑开 —— 表现为「有时对有时错」（2026-10-11 复现）。
   * 因此这里记住见过的最大值，之后即使当前是沉浸态也返回该值。
   */
  private cachedTopVp: number = 0;
  private cachedBottomVp: number = 0;
  private cachedStatusBarPx: number = 0;
  /**
   * 应用**请求的**系统栏显隐意图（由 `set_system_ui_visibility` 写入），默认 true
   * （启动时书库页会立刻请求显示）。
   *
   * 为什么按"意图"而不是"避让区实测值"给 insets：系统栏显隐是异步的，
   * 实测值会有滞后/塌陷（隐藏时读数为 0）。网页只在少数时机取值，若取到滞后值，
   * 就会出现「菜单与状态栏重合」或「阅读时顶部多留一条」两种错误。
   * 按意图给值则**任何时刻取值都是对的**：
   *   意图=显示 → 返回设备状态栏固有高度（44vp，实测学习得到）
   *   意图=隐藏 → 返回 0（阅读全屏，正文顶到边）
   */
  private requestedSystemUIVisible: boolean = true;
  private controller: webview.WebviewController | undefined = undefined;
  private paths: PathDomain | undefined = undefined;
  private files: FsDomain | undefined = undefined;
  private wins: WindowDomain | undefined = undefined;
  private legacy: LegacyBridge = new LegacyBridge();

  static addPendingOpenUrl(url: string): void {
    LegacyBridge.addPendingOpenUrl(url);
  }

  static takePendingOpenUrls(): Array<string> {
    return LegacyBridge.takePendingOpenUrls();
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
    this.paths = new PathDomain(context.filesDir, context.cacheDir);
    this.files = new FsDomain(this.paths);
    this.files.setDiagSink((message: string) => this.diag(message));
    this.wins = new WindowDomain(context, (message: string) => this.diag(message));
    // 尚未迁移的域继续用旧实现；诊断统一走本文件的字节正确写入。
    this.legacy.setContext(context);
    this.legacy.setDiagSink((message: string) => this.diag(message));
  }

  setController(controller: webview.WebviewController): void {
    this.controller = controller;
    this.legacy.setController(controller);
  }

  /** 2in1 沉浸式窗口：隐藏装饰与标题栏按钮，拖拽交给网页自绘工具条。 */
  async initWindow(): Promise<void> {
    if (this.wins === undefined) return;
    try {
      // 所有形态都沉浸（2026-10-11 第二轮）：移动端不再靠「退出全屏」避让，
      // 而由 set_system_ui_visibility + 网页按状态栏高度撑开来实现（与安卓一致）。
      this.diag('initWindow: immersive for deviceType=' + String(deviceInfo.deviceType));
      const win = this.wins.sharedWindow();
      if (win === undefined) {
        this.diag('initWindow skipped: no shared window yet');
        return;
      }
      win.setWindowDecorVisible(false);
      win.setWindowLayoutFullScreen(true);
      // 平板不支持该能力（真机日志：Capability not supported [setWindowTitleMoveEnabled]）——
      // 它只是"隐藏标题栏后别抢指针事件"的桌面优化，失败不该中断后面的步骤。
      try {
        win.setWindowTitleMoveEnabled(false);
      } catch (error) {
        this.diag('setWindowTitleMoveEnabled unsupported (ignored): ' + String(error));
      }
    } catch (error) {
      this.diag('initWindow failed: ' + String(error));
    }
  }

  /**
   * `get_executable_dir` —— 必须返回**不可能出现 settings.json** 的目录。
   *
   * 上游用它做"便携版"探测：
   *   `if (exists(`${execDir}/settings.json`)) → isPortableApp = true`，
   * 一旦为真，整个数据根会被设成 `execDir`（`customRootDir: execDir`），
   * 于是 `files/data/Readest/Books` 里已有的书库会被绕过，应用改看
   * `files/Readest/Books`，表现为"书库突然空了 + 打开书籍报错"。
   *
   * 旧实现返回 `context.filesDir`（可写数据目录），而设置文件恰好可能落在
   * 那里，于是这个探测会**自我锁定**：一旦命中就永远是便携版，再也回不去。
   * 安装目录（bundleCodeDir）是只读的，settings.json 永远不会出现在那里。
   */
  /**
   * 启动时**只打一次**的设备形态诊断。
   *
   * 为什么需要：本项目声明全端（2in1 / tablet / phone），但只在 2in1 上验证过。
   * 真机拿到手机/平板时，第一件事就是看这一行 —— 它会告诉我们系统认定的形态、
   * 屏幕尺寸、密度与安全区，从而判断"是不是走了预期的分支"。
   */
  private diagDeviceFormOnce(): void {
    if (this.deviceFormLogged) return;
    this.deviceFormLogged = true;
    try {
      const d = display.getDefaultDisplaySync();
      let insets = '';
      try {
        const win = AppStorage.get<window.Window>('readestMainWindow');
        if (win) {
          const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          insets = ' avoid.top=' + String(avoid.topRect.height) +
            ' avoid.bottom=' + String(avoid.bottomRect.height);
        }
      } catch (e2) {
        insets = ' avoid=unavailable';
      }
      this.diag('device form: deviceType=' + String(deviceInfo.deviceType) +
        ' osFullName=' + String(deviceInfo.osFullName) +
        ' screen=' + String(d.width) + 'x' + String(d.height) +
        ' density=' + String(d.densityPixels) + insets);
    } catch (error) {
      this.diag('device form: FAILED ' + String(error));
    }
  }

  private executableDir(): string {
    if (this.context === undefined) return '';
    return this.context.bundleCodeDir;
  }

  closeAll(): void {
    if (this.files !== undefined) this.files.closeAll();
  }

  methodList(): Array<string> {
    return ['invoke', 'invokeAsync'];
  }

  supportedDomains(): Array<string> {
    return MIGRATED_PREFIXES;
  }

  // ── 传输 ─────────────────────────────────────────────────────────────

  invoke(cmd: string, argsJson: string): string {
    this.diagDeviceFormOnce();
    // 启动早期必须由我们钉死语义的命令，一律不进旧实现。
    if (cmd === 'get_executable_dir') return this.ok(this.executableDir());
    // 非 `plugin:` 前缀的原生命令：上游用它做「从文件夹导入」的目录扫描
    // （Rust WalkDir）。没实现时应用会退到 JS 递归回退，而回退路径又被
    // path|join 压坏成 `file:/docs/…` → stat 全 ENOENT。见 FsDomain.readDirectoryTree。
    if (cmd === 'read_dir') return this.readDirectoryTree(argsJson);
    // 设备形态（2in1 / tablet / phone）：shim 注入时同步取走，供网页区分形态
    // （隐藏窗口三键、决定状态栏策略）。
    if (cmd === 'get_device_form') return this.ok(String(deviceInfo.deviceType));
    // 上游 plugin:native-bridge 的两个状态栏命令 —— 安卓那套「阅读沉浸 / 菜单保留状态栏」
    // 行为的落点（见 notes/multidevice-adaptation-analysis.md 第十节）。
    if (cmd === 'plugin:native-bridge|get_status_bar_height') return this.statusBarHeightJson();
    if (cmd === 'plugin:native-bridge|get_safe_area_insets') return this.safeAreaInsetsJson();
    if (cmd === 'plugin:native-bridge|set_system_ui_visibility') return this.applySystemUIVisibility(argsJson);
    // Tauri core 命令：Resource 基类的 close（备份关流时会调）。
    if (cmd === 'plugin:resources|close') return this.closeResource(argsJson);
    if (!this.isMigrated(cmd)) {
      // 未迁移的域完全交给旧实现（含它自己的错误信封格式）。
      return this.legacy.invoke(cmd, argsJson);
    }
    try {
      const args: ESObject = argsJson && argsJson.length > 0 ? JSON.parse(argsJson) : {};
      return this.ok(this.dispatch(cmd, args));
    } catch (error) {
      this.diag('invoke FAIL ' + cmd + ' err=' + String(error) +
        ' args=' + String(argsJson).slice(0, 220));
      hilog.warn(DOMAIN, TAG, 'invoke %{public}s failed: %{public}s', cmd, String(error));
      return this.fail(error);
    }
  }

  /** 让网页侧重新读取安全区（派发 focus，命中 useSafeAreaInsets 的监听）。 */
  private notifyInsetsChanged(): void {
    if (this.controller === undefined) return;
    this.controller.runJavaScript("window.dispatchEvent(new Event('focus'))")
      .catch((error: ESObject) => {
        this.diag('notifyInsetsChanged failed: ' + String(error));
      });
  }

  /**
   * `plugin:native-bridge|get_safe_area_insets` -> `{top,right,bottom,left}`，单位 **vp / CSS px**。
   *
   * 上游在 Android/iOS 上用它绕过「WebView 139 里 env(safe-area-inset-*) 恒为 0」的
   * Chromium 缺陷；鸿蒙 ArkWeb **同样不填充**这些 CSS 变量（真机实测 shim 读到的
   * safeAreaTop 为空）。所以移动形态必须走这条原生通路，否则 insets 恒 0 ——
   * 症状就是阅读器顶栏不加 padding、与状态栏重叠；而书库用的是
   * max(insets.top, statusBarHeight) 所以看起来是对的，造成「有时对有时错」的错觉。
   */
  private safeAreaInsetsJson(): string {
    let top = 0;
    let bottom = 0;
    try {
      const win = this.wins === undefined ? undefined : this.wins.sharedWindow();
      if (win !== undefined) {
        const density = display.getDefaultDisplaySync().densityPixels;
        const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        top = Math.round(avoid.topRect.height / density);
        bottom = Math.round(avoid.bottomRect.height / density);
        // 系统栏隐藏时会读到 0：只往上记，不往下覆盖（见 cachedTopVp 的说明）。
        if (top > this.cachedTopVp) this.cachedTopVp = top;
        if (bottom > this.cachedBottomVp) this.cachedBottomVp = bottom;
      }
    } catch (error) {
      this.diag('get_safe_area_insets failed: ' + String(error));
    }
    // 返回**稳定值**（设备状态栏的固有高度），与"此刻是否隐藏"无关 —— 这是关键：
    // 避让与否由网页侧的 systemUIVisible 决定（没菜单→0、有菜单→该高度），
    // 若这里返回"实时值"，在系统栏刚显示、避让区尚未更新时会取到 0，
    // 菜单就再也不会撑开（2026-10-11 真机复现："菜单跟状态栏又重合了"）。
    const wantsVisible = this.requestedSystemUIVisible;
    top = wantsVisible ? this.cachedTopVp : 0;
    bottom = wantsVisible ? this.cachedBottomVp : 0;
    this.diag('get_safe_area_insets -> top=' + String(top) + ' bottom=' + String(bottom) +
      ' (intent=' + String(wantsVisible) + ', learnedTop=' + String(this.cachedTopVp) + ')');
    return this.ok(JSON.parse('{"top":' + String(top) + ',"right":0,"bottom":' +
      String(bottom) + ',"left":0}') as ESObject);
  }

  /**
   * `plugin:native-bridge|get_status_bar_height` -> `{ height }`，单位**物理 px**。
   *
   * 上游拿到后会 `/ window.devicePixelRatio` 换成 CSS px 再用于顶栏 padding，
   * 所以这里给避让区 TYPE_SYSTEM.topRect.height（平板实测 104 = 44vp × 2.375）。
   */
  private statusBarHeightJson(): string {
    let height = 0;
    try {
      const win = this.wins === undefined ? undefined : this.wins.sharedWindow();
      if (win !== undefined) {
        const measured = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
        if (measured > this.cachedStatusBarPx) this.cachedStatusBarPx = measured;
        height = this.requestedSystemUIVisible ? this.cachedStatusBarPx : 0;
      }
    } catch (error) {
      this.diag('get_status_bar_height failed: ' + String(error));
    }
    this.diag('get_status_bar_height -> ' + String(height));
    return this.ok(JSON.parse('{"height":' + String(height) + '}') as ESObject);
  }

  /**
   * `plugin:native-bridge|set_system_ui_visibility` -> `{ success }`。
   *
   * 上游在「菜单/顶栏出现」时请求 visible=true（露出系统栏，网页再按状态栏高度撑开），
   * 在纯阅读（沉浸）时请求 visible=false（隐藏系统栏）—— 正是安卓上的表现。
   */
  private applySystemUIVisibility(argsJson: string): string {
    let visible = false;
    try {
      const args: ESObject = argsJson && argsJson.length > 0 ? JSON.parse(argsJson) : {};
      const payload: ESObject = args ? args['payload'] : undefined;
      visible = payload ? payload['visible'] === true : false;
    } catch (error) {
      this.diag('set_system_ui_visibility 参数解析失败: ' + String(error));
    }
    // ── 手机与平板策略不同（2026-10-11 用户确认）────────────────────────────
    // 手机：**永远**在状态栏下方（状态栏常显、内容一直让开它）—— 因此忽略应用的
    //       "隐藏系统栏"请求；
    // 平板/2in1：保持"沉浸 ↔ 菜单避让"的切换（阅读时隐藏、菜单出现时露出）。
    if (String(deviceInfo.deviceType) === 'phone' && !visible) {
      this.diag('set_system_ui_visibility: phone 形态忽略隐藏请求，状态栏保持显示');
      visible = true;
    }
    try {
      const win = this.wins === undefined ? undefined : this.wins.sharedWindow();
      if (win !== undefined) {
        const bars: Array<'status' | 'navigation'> = visible ? ['status', 'navigation'] : [];
        win.setWindowSystemBarEnable(bars).then(() => {
          // 系统栏显隐会改变避让区（隐藏时塌成 0、显示时 44vp），必须让网页重新取值，
          // 否则 padding 会停留在上一次的状态（表现为菜单与状态栏错位）。
          // `focus` 命中上游 useSafeAreaInsets 里的监听（-- additional safeguard for iOS）。
          this.notifyInsetsChanged();
        }).catch((error: ESObject) => {
          this.diag('setWindowSystemBarEnable failed: ' + String(error));
        });
      }
      // 内置浏览器是 **ArkTS 覆盖层**（不在 web insets 管辖内），把「当前顶部要避让多少 vp」
      // 放进 AppStorage，由 pages/Index.ets 使用；状态栏隐藏时归零。
      try {
        let topVp = 0;
        const winForTop = this.wins === undefined ? undefined : this.wins.sharedWindow();
        if (winForTop !== undefined) {
          const density = display.getDefaultDisplaySync().densityPixels;
          const avoid = winForTop.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const measured = Math.round(avoid.topRect.height / density);
          if (measured > this.cachedTopVp) this.cachedTopVp = measured;
        }
        if (visible) topVp = this.cachedTopVp;
        AppStorage.setOrCreate('readestTopSafe', topVp);
      } catch (error) {
        this.diag('readestTopSafe update failed: ' + String(error));
      }
      this.requestedSystemUIVisible = visible;
      this.diag('set_system_ui_visibility visible=' + String(visible) +
        ' -> insetsTop=' + String(visible ? this.cachedTopVp : 0));
      return this.ok(JSON.parse('{"success":true}') as ESObject);
    } catch (error) {
      this.diag('set_system_ui_visibility failed: ' + String(error));
      return this.ok(JSON.parse('{"success":false}') as ESObject);
    }
  }

  /**
   * `plugin:resources|close` —— Tauri 的 **core** 命令（`Resource` 基类的 close）。
   *
   * 2026-10-11 真机暴露：备份回退路径（zip.js 关流）会调它，而我们没实现 →
   * 整个备份以 `unsupported bridge command: plugin:resources|close` 失败。
   * 在本移植里 rid 就是 FsDomain 分配的文件句柄编号 → 释放它即可；
   * 其它来源的 rid 不归它管 → **找不到也当已释放、绝不抛错**。
   */
  private closeResource(argsJson: string): string {
    let rid = -1;
    try {
      const parsed: ESObject = JSON.parse(argsJson) as ESObject;
      rid = argNumber(wireArgs(parsed), 'rid', -1);
    } catch (error) {
      this.diag('plugin:resources|close 参数解析失败: ' + String(error));
    }
    let released = false;
    try {
      released = this.requireFiles().closeRid(rid);
    } catch (error) {
      this.diag('plugin:resources|close 释放失败: ' + String(error));
    }
    this.diag('plugin:resources|close rid=' + String(rid) + ' released=' + String(released));
    return this.ok(null);
  }

  /** 原生命令 `read_dir` 的信封处理：`{path, recursive, extensions}` → `[{path,size}]`。 */
  private readDirectoryTree(argsJson: string): string {
    try {
      const args: ESObject = argsJson && argsJson.length > 0 ? JSON.parse(argsJson) : {};
      const path = args ? String(args['path'] === undefined ? '' : args['path']) : '';
      if (path.length === 0) return this.ok([]);
      const recursive = args ? args['recursive'] === true : false;
      const rawExts: ESObject = args ? args['extensions'] : undefined;
      const extensions: Array<string> = Array.isArray(rawExts) ? rawExts as Array<string> : [];
      return this.ok(this.requireFiles().readDirectoryTree(path, extensions, recursive));
    } catch (error) {
      this.diag('invoke FAIL read_dir err=' + String(error));
      return this.fail(error);
    }
  }

  invokeAsync(cmd: string, argsJson: string, callbackId: number): string {
    if (!this.isMigrated(cmd)) {
      return this.legacy.invokeAsync(cmd, argsJson, callbackId);
    }
    const args: ESObject = argsJson && argsJson.length > 0 ? JSON.parse(argsJson) : {};
    this.dispatchAsync(cmd, args).then((result: ESObject) => {
      this.resolveCallback(callbackId, result);
    }).catch((error: ESObject) => {
      this.diag('invokeAsync FAIL ' + cmd + ' err=' + String(error));
      hilog.warn(DOMAIN, TAG, 'invokeAsync %{public}s failed: %{public}s', cmd, String(error));
      if (this.controller !== undefined) {
        this.controller.runJavaScript(
          `window.__READEST_BRIDGE__.reject(${callbackId}, ${JSON.stringify(String(error))})`);
      }
    });
    return '';
  }

  private isMigrated(cmd: string): boolean {
    for (let i = 0; i < MIGRATED_PREFIXES.length; i++) {
      if (cmd.indexOf(MIGRATED_PREFIXES[i]) === 0) return true;
    }
    return false;
  }

  private resolveCallback(callbackId: number, result: ESObject): void {
    if (this.controller === undefined) return;
    this.controller.runJavaScript(
      `window.__READEST_BRIDGE__.resolve(${callbackId}, ${this.body(result)})`);
  }

  private dispatch(cmd: string, rawArgs: ESObject): ESObject {
    // fs 域必须拿到**完整信封**：写的 path/options 在 `__readestHeaders` 里，
    // 先 wireArgs 拆包会把 path 丢掉（症状：path 变空串、settings.json 永远存不下）。
    if (cmd.indexOf(FS_PREFIX) === 0) {
      return this.requireFiles().handle(cmd.slice(FS_PREFIX.length), rawArgs);
    }
    const args: ESObject = wireArgs(rawArgs);
    if (cmd.indexOf(PATH_PREFIX) === 0) return this.requirePaths().handle(cmd.slice(PATH_PREFIX.length), args);
    // 窗口命令在 shim 的 ASYNC_COMMANDS 之外，走同步路径，所以这里同步处理。
    if (cmd.indexOf(WINDOW_PREFIX) === 0) return this.requireWins().handle(cmd.slice(WINDOW_PREFIX.length), args);
    throw new Error('unsupported bridge command: ' + cmd);
  }

  private async dispatchAsync(cmd: string, rawArgs: ESObject): Promise<ESObject> {
    // 已迁移的三个域都是同步的；保留异步入口以便后续接入异步域。
    return this.dispatch(cmd, rawArgs);
  }

  private requirePaths(): PathDomain {
    if (this.paths === undefined) throw new Error('bridge context is not ready');
    return this.paths;
  }

  private requireFiles(): FsDomain {
    if (this.files === undefined) throw new Error('bridge context is not ready');
    return this.files;
  }

  private requireWins(): WindowDomain {
    if (this.wins === undefined) throw new Error('bridge context is not ready');
    return this.wins;
  }

  /** RawJson = 这段已经是序列化好的 JSON（字节结果走这条路）。 */
  private body(data: ESObject): string {
    if (data instanceof RawJson) return (data as RawJson).json;
    if (data === undefined) return 'null';
    return JSON.stringify(data);
  }

  private ok(data: ESObject): string {
    return '{"ok":true,"data":' + this.body(data) + '}';
  }

  private fail(error: ESObject): string {
    return '{"ok":false,"error":' + JSON.stringify(String(error)) + '}';
  }

  // ── 诊断 ─────────────────────────────────────────────────────────────

  /**
   * 追加一行诊断日志到 `cache/bridge-diag-<MMDD>.log`。
   *
   * 必须按字节写：`fs.writeSync(fd, string)` 在设备上写入 0 字节，上一版因此
   * 长期拿到空日志，排障只能靠猜。
   */
  /**
   * **成功流水**是否也写进诊断（失败/异常永远写）。
   *
   * 为什么需要这个开关：排查期间我们加了不少"每次操作都记一条"的探针
   * （每次写盘、每次改窗口……），它们是定位问题的关键；但**日常使用**下这些行会
   * 持续写盘（例如阅读时每 ~1.5s 存一次书签）。
   *
   * 所以约定一条线：
   *   · **失败 / 异常 / 状态变更** → 永远记录（诊断的价值所在）；
   *   · **成功流水** → 只有本开关为 true 才记录。
   *
   * 出"干净版"时把这里改成 false 即可（一行），无需逐处拔探针。
   * 其它开关见 notes/pre-submission-checklist.md 的「诊断与探针」一节。
   */
  private static readonly DIAG_SUCCESS_LOGS: boolean = true;

  /** 判定一条日志是否属于"成功流水"（越靠前越省事，故前缀匹配）。 */
  private static isSuccessNoise(message: string): boolean {
    const chatty: Array<string> = [
      'fsWrite ok:',
      'fsWrite target:',
      'resize ok ->',
      'window set_size',
      'window maximize requested',
      'window unmaximize requested',
      'window toggle_maximize:',
      'plugin:resources|close rid=',
      'dialogSave: defaultPath=',
      'dialogSave: uris=',
      'dialogSave: real path=',
      'plugin:resources|close ',
    ];
    for (let i = 0; i < chatty.length; i++) {
      if (message.indexOf(chatty[i]) === 0) return true;
    }
    return false;
  }

  diag(message: string): void {
    if (this.context === undefined) return;
    if (!ReadestBridge.DIAG_SUCCESS_LOGS && ReadestBridge.isSuccessNoise(message)) return;
    try {
      const now = new Date();
      const mm = String(now.getMonth() + 1).padStart(2, '0');
      const dd = String(now.getDate()).padStart(2, '0');
      const ts = `${now.getHours()}:${now.getMinutes()}:${now.getSeconds()}.${now.getMilliseconds()}`;
      const sized = encodeUtf8Sized(ts + ' ' + message + '\n');
      const path = this.context.cacheDir + '/bridge-diag-' + mm + dd + '.log';
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE);
      try {
        if (sized.size > 0) fs.writeSync(file.fd, exactBuffer(sized.bytes, sized.size));
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (_error) {
      // 诊断自身绝不能影响主流程。
    }
  }

  /** 医生页用来把结果落到文件（同 cache 目录，便于取回）。 */
  writeReport(name: string, content: string): string {
    if (this.context === undefined) return '';
    const path = this.context.cacheDir + '/' + name;
    const sized = encodeUtf8Sized(content);
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      if (sized.size > 0) fs.writeSync(file.fd, exactBuffer(sized.bytes, sized.size));
    } finally {
      fs.closeSync(file.fd);
    }
    return path;
  }

  // ── 未迁移域的门面（转发给 LegacyBridge，供页面直接调用）──────────────

  interceptRequest(request: WebResourceRequest): WebResourceResponse | undefined {
    return this.legacy.interceptRequest(request);
  }

  loadInjectScript(): string {
    return this.legacy.loadInjectScript();
  }

  lastBrowserDownloadPath(): string {
    return this.legacy.lastBrowserDownloadPath();
  }

  setImportStatusSink(sink: (state: string, filename: string) => void): void {
    this.legacy.setImportStatusSink(sink);
  }

  setBrowserOpener(fn: (url: string, clipLabel: string, closeLabel: string) => Promise<string>): void {
    this.legacy.setBrowserOpener(fn);
  }

  saveBrowserClipHtml(html: string): void {
    this.legacy.saveBrowserClipHtml(html);
  }

  readBrowserClip(): string {
    return this.legacy.readBrowserClip();
  }

  emitWebBrowserDownload(url: string, path: string, filename: string, success: boolean, errorText: string): void {
    this.legacy.emitWebBrowserDownload(url, path, filename, success, errorText);
  }

  suggestedFileName(url: string): string {
    return this.legacy.suggestedFileName(url);
  }

  browserDownloadsDir(): string {
    return this.legacy.browserDownloadsDir();
  }

  browserCacheRoot(): string {
    return this.legacy.browserCacheRoot();
  }

  webBrowserArchiveDir(path: string): string {
    return this.legacy.webBrowserArchiveDir(path);
  }

  downloadToFile(url: string, path: string): Promise<void> {
    return this.legacy.downloadToFile(url, path);
  }

  removePath(path: string): void {
    this.legacy.removePath(path);
  }

  listCacheDir(dir: string): Array<string> {
    return this.legacy.listCacheDir(dir);
  }

  pathMtimeMs(path: string): number {
    return this.legacy.pathMtimeMs(path);
  }

  handleTtsEvent(utteranceId: string, code: string, message: string): void {
    this.legacy.handleTtsEvent(utteranceId, code, message);
  }
}
