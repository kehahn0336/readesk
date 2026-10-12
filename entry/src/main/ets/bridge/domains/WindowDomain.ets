/**
 * `plugin:window|*` —— Tauri 窗口插件（HarmonyOS 真实可用的子集）。
 *
 * 为什么是**同步**的：`readest-bridge.js` 的 ASYNC_COMMANDS 里没有 `plugin:window|*`，
 * 窗口命令全部走同步 `invoke()`。因此这里必须同步返回结果（尤其 `is_maximized`
 * 要立刻给布尔值，否则自绘标题栏的三键状态会错）。
 *
 * 三条实机约束：
 *  1. 最大化判定**不能**用 `getWindowStatus()`：API 26 / 2in1 上枚举不可靠（浮动=4，从不返回 MAXIMIZE=2）。
 *     用几何判定（窗口矩形 ≥ 显示屏 95%）。
 *  2. 关闭主窗口**不能**用 `destroyWindow()`：只对系统窗口/应用子窗口生效，主窗口必须 `terminateSelf()`。
 *  3. 最大化状态下 `startMoving()` 会"先还原再拖拽"（表现为点一下标题栏就掉出最大化），所以跳过。
 */
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { argNumber, argString } from '../BridgeProtocol';

// 2in1 上"最大化"占的是**工作区**（扣掉任务栏/停靠栏），不是整块屏幕 —— 所以
// 比例不能卡在 0.95（2026-10-10 真机反馈"最大化按钮无法使用"就与此有关：
// 判定永远为 false → toggle 每次只执行"最大化" → 第二次点毫无反应）。
const GEOMETRY_RATIO = 0.88;
const WINDOW_KEY = 'readestMainWindow';

export class WindowDomain {
  private context: common.UIAbilityContext;
  private onDiag: (message: string) => void;
  /** EntryAbility 通过 AppStorage 交来的主窗口（唯一同步可得的来源）。 */
  private win: window.Window | undefined = undefined;

  constructor(context: common.UIAbilityContext, onDiag: (message: string) => void) {
    this.context = context;
    this.onDiag = onDiag;
    this.adoptSharedWindow();
  }

  /**
   * `windowStage.getMainWindowSync()` 只能在 Ability 里调用，桥只有 context，
   * 所以由 EntryAbility 把窗口存进 AppStorage，这里取用。
   */
  private adoptSharedWindow(): void {
    const shared = AppStorage.get<window.Window>(WINDOW_KEY);
    if (shared !== undefined) this.win = shared;
  }

  /** 兜底：AppStorage 还没就绪时异步取一次并缓存。 */
  private ensureWindow(): window.Window | undefined {
    if (this.win !== undefined) return this.win;
    this.adoptSharedWindow();
    if (this.win !== undefined) return this.win;
    window.getLastWindow(this.context).then((win: window.Window) => {
      this.win = win;
    }).catch((error: ESObject) => {
      this.onDiag('getLastWindow failed: ' + String(error));
    });
    return undefined;
  }

  /** 供桥做窗口初始化（同样只在拿到共享窗口时可用）。 */
  sharedWindow(): window.Window | undefined {
    return this.ensureWindow();
  }

  /**
   * 我们自己是否把它最大化过。
   *
   * 为什么需要：API 26 的 2in1 上 `getWindowStatus()` 不返回 MAXIMIZE、几何判定又受
   * 工作区大小影响 —— 单靠任何一路都可能误判，导致 toggle 永远朝一个方向走。
   * 这里记住"我们发出的动作"，再用几何与 `FLOATING` 反证校正。
   */
  private maximizedHint: boolean = false;

  /**
   * 全屏状态。上游 `tauriHandleToggleFullscreen` **完全靠它分支**：
   *   if (await isFullscreen()) { setFullscreen(false); … }   // 退出
   *   else                      { …; setFullscreen(true); }    // 进入
   * 所以它既不能恒 true（退出能用、进入永远轮不到），也不能恒 false（反之）。
   * 必须如实维护 —— 我们才知道自己刚才做了什么。
   */
  private fullscreenHint: boolean = false;

  handle(cmd: string, args: ESObject): ESObject {
    switch (cmd) {
      case 'set_title': {
        // 标题栏被隐藏（Readest 自绘三键），标题只对任务栏有意义，失败不影响功能。
        const win = this.ensureWindow();
        if (win !== undefined) {
          try {
            win.setWindowTitle(argString(args, 'title'));
          } catch (error) {
            this.onDiag('window set_title ignored: ' + String(error));
          }
        }
        return null;
      }
      case 'minimize': {
        const win = this.ensureWindow();
        if (win !== undefined) win.minimize();
        return null;
      }
      case 'maximize': {
        const win = this.ensureWindow();
        this.maximizedHint = true;
        this.onDiag('window maximize requested');
        if (win !== undefined) win.maximize().catch((error: ESObject) => {
          this.onDiag('window maximize failed: ' + String(error));
        });
        return null;
      }
      case 'unmaximize': {
        const win = this.ensureWindow();
        this.maximizedHint = false;
        this.onDiag('window unmaximize requested');
        if (win !== undefined) win.recover().catch((error: ESObject) => {
          const text = String(error);
          // 上游会在"本来就没最大化"时也调 unmaximize → `Repeated operation` 属正常，
          // 不记成失败（否则真问题会被这行噪音淹掉）。
          if (text.indexOf('Repeated operation') >= 0) {
            this.onDiag('window recover: already normal (ignored)');
          } else {
            this.onDiag('window recover failed: ' + text);
          }
        });
        return null;
      }
      case 'toggle_maximize': {
        const win = this.ensureWindow();
        if (win === undefined) return null;
        const nowMaximized = this.resolveMaximized(win);
        this.onDiag('window toggle_maximize: was=' + String(nowMaximized));
        this.maximizedHint = !nowMaximized;
        const action = nowMaximized ? win.recover() : win.maximize();
        action.catch((error: ESObject) => {
          this.onDiag('window toggle action failed: ' + String(error));
        });
        return null;
      }
      case 'is_maximized': {
        const win = this.ensureWindow();
        return win === undefined ? false : this.resolveMaximized(win);
      }
      case 'close':
      case 'destroy':
        // 主窗口销毁必须走 terminateSelf：destroyWindow 对主窗口是 no-op。
        // `destroy` 与 `close` 同义（上游 destroyWindow() 走 destroy）。
        this.context.terminateSelf();
        return null;
      case 'get_all_windows':
        // 上游只用来判断"我是不是第一个窗口"（useOpenWithBooks → isFirstWindow）：
        // 比较排序后的第一个 label 与当前窗口 label。shim 的 metadata 里
        // currentWindow.label = 'main'，所以这里必须回 ['main'] 才能判为 true。
        return ['main'];
      case 'hide': {
        // 与旧实现一致：没有真正的"隐藏"语义，退化为最小化。
        const win = this.ensureWindow();
        if (win !== undefined) win.minimize();
        return null;
      }
      case 'start_dragging': {
        const win = this.ensureWindow();
        if (win === undefined) return null;
        // 最大化时 startMoving 会先还原再拖拽，表现为点一下就掉出最大化。
        // 判据用**状态**而不是几何：满屏窗口不等于已最大化（否则退出最大化后拖不动）。
        if (this.resolveMaximized(win)) {
          this.onDiag('start_dragging ignored: window is maximized');
          return null;
        }
        try {
          win.startMoving();
        } catch (error) {
          this.onDiag('startMoving failed: ' + String(error));
        }
        return null;
      }
      case 'set_fullscreen': {
        const win = this.ensureWindow();
        if (win === undefined) return null;
        const want: ESObject = args ? args['fullscreen'] : undefined;
        const on = want === undefined ? true : want === true;
        this.fullscreenHint = on;
        this.onDiag('window set_fullscreen(' + String(on) + ')');
        // 本移植没有系统装饰（自绘标题栏），所以"全屏"≈铺满整屏、"退出"≈还原几何。
        // 布局标志始终为 true（边到边是我们的常态外观），变化的是窗口几何。
        win.setWindowLayoutFullScreen(true).catch((error: ESObject) => {
          this.onDiag('setWindowLayoutFullScreen failed: ' + String(error));
        });
        if (on) {
          this.maximizedHint = true;
          win.maximize().catch((error: ESObject) => {
            this.onDiag('fullscreen maximize failed: ' + String(error));
          });
        } else {
          this.maximizedHint = false;
          win.recover().catch((error: ESObject) => {
            const text = String(error);
            if (text.indexOf('Repeated operation') >= 0) {
              this.onDiag('fullscreen recover: already normal (ignored)');
            } else {
              this.onDiag('fullscreen recover failed: ' + text);
            }
          });
        }
        return null;
      }
      case 'is_fullscreen':
        // 如实返回我们自己的全屏状态。**不要恒 true / 恒 false**：
        // 上游 tauriHandleToggleFullscreen 与 tauriHandleToggleMaximize **都**靠它分支，
        // 恒 true 会让"最大化"永远变成 unmaximize，恒 false 会让"退出全屏"永远进不去 ——
        // 2026-10-10 两个方向都真机上撞过。
        return this.fullscreenHint;
      case 'scale_factor':
        return display.getDefaultDisplaySync().densityPixels;
      case 'inner_size':
      case 'outer_size': {
        const win = this.ensureWindow();
        if (win === undefined) return null;
        const rect = win.getWindowProperties().windowRect;
        const size: window.Size = { width: rect.width, height: rect.height };
        return size;
      }
      case 'inner_position':
      case 'outer_position': {
        const win = this.ensureWindow();
        if (win === undefined) return null;
        const rect = win.getWindowProperties().windowRect;
        const position: window.Position = { x: rect.left, y: rect.top };
        return position;
      }
      case 'set_size': {
        const win = this.ensureWindow();
        const size = this.tauriSize(args);
        if (win !== undefined && size !== undefined) {
          if (this.skipResizeWhileToggled(win, size.width, size.height)) return null;
          this.onDiag('window set_size -> ' + String(size.width) + 'x' + String(size.height));
          this.resizeWithRetry(win, size.width, size.height, 0);
        } else if (size === undefined) {
          this.onDiag('window set_size: 载荷无法解析 args=' + JSON.stringify(args).slice(0, 160));
        }
        return null;
      }
      case 'set_position': {
        const win = this.ensureWindow();
        const pos = this.tauriPosition(args);
        if (win !== undefined && pos !== undefined) {
          const rect = win.getWindowProperties().windowRect;
          if (pos.x === rect.left && pos.y === rect.top) return null;
          this.moveWithRetry(win, pos.x, pos.y, 0);
        }
        return null;
      }
      case 'primary_monitor':
      case 'current_monitor': {
        return this.monitorJson(display.getDefaultDisplaySync());
      }
      case 'available_monitors': {
        // 注意：`display.getAllDisplays()` 在 ArkTS 上是 **Promise**，同步的 handle 用不了。
        // 本移植面向单屏（2in1 / 平板 / 手机内置屏），返回 primary 即可 ——
        // app 侧主要用 `primary_monitor` / `current_monitor`。
        const one: Array<ESObject> = [];
        one.push(this.monitorJson(display.getDefaultDisplaySync()));
        return one;
      }
      case 'show': {
        const win = this.ensureWindow();
        if (win !== undefined) {
          win.showWindow().catch((error: ESObject) => {
            this.onDiag('showWindow failed: ' + String(error));
          });
        }
        return null;
      }
      default:
        throw new Error('unsupported bridge command: plugin:window|' + cmd);
    }
  }

  /**
   * 解析 Tauri 的 `Size` 载荷：`{ value: { Physical|Logical: { width, height } } }`。
   *
   * **不是扁平字段**。2026-10-10 真机日志实证：
   *   args={"label":"main","value":{"Physical":{"width":2089,"height":1393}}}
   * 旧实现按扁平 `width/height` 读 → `resize(0, 0)` → 系统回 `Parameter error`。
   */
  private tauriSize(args: ESObject): window.Size | undefined {
    const value: ESObject = args ? args['value'] : undefined;
    if (value) {
      const physical: ESObject = value['Physical'];
      if (physical) {
        return { width: Number(physical['width']), height: Number(physical['height']) };
      }
      const logical: ESObject = value['Logical'];
      if (logical) {
        // 逻辑像素 → 物理像素（HarmonyOS 的 resize 收物理 px）
        const scale = display.getDefaultDisplaySync().densityPixels;
        return {
          width: Math.round(Number(logical['width']) * scale),
          height: Math.round(Number(logical['height']) * scale),
        };
      }
    }
    // 兼容旧式扁平字段（历史验收里用过）
    const w: ESObject = args ? args['width'] : undefined;
    const h: ESObject = args ? args['height'] : undefined;
    if (w !== undefined && h !== undefined) {
      return { width: Number(w), height: Number(h) };
    }
    return undefined;
  }

  /** 解析 Tauri 的 `Position` 载荷：`{ value: { Physical|Logical: { x, y } } }`。 */
  private tauriPosition(args: ESObject): window.Position | undefined {
    const value: ESObject = args ? args['value'] : undefined;
    if (value) {
      const physical: ESObject = value['Physical'];
      if (physical) return { x: Number(physical['x']), y: Number(physical['y']) };
      const logical: ESObject = value['Logical'];
      if (logical) {
        const scale = display.getDefaultDisplaySync().densityPixels;
        return { x: Math.round(Number(logical['x']) * scale), y: Math.round(Number(logical['y']) * scale) };
      }
    }
    const x: ESObject = args ? args['x'] : undefined;
    const y: ESObject = args ? args['y'] : undefined;
    if (x !== undefined && y !== undefined) return { x: Number(x), y: Number(y) };
    return undefined;
  }

  /**
   * Tauri 的 `Monitor` 形状（app 用它取显示器 / 工作区）。
   *
   * 用 `JSON.parse` 构造而不是对象字面量：ArkTS 禁止"无类型对象字面量"
   * （`arkts-no-untyped-obj-literals`），嵌套的 `{ Physical: { … } }` 正好撞上。
   */
  private monitorJson(screen: display.Display): ESObject {
    const w = String(screen.width);
    const h = String(screen.height);
    const size = '{"Physical":{"width":' + w + ',"height":' + h + '}}';
    const pos = '{"Physical":{"x":0,"y":0}}';
    const json = '{"name":"' + String(screen.id) + '","size":' + size + ',"position":' + pos +
      ',"scaleFactor":' + String(screen.densityPixels) + ',"workArea":{"size":' + size +
      ',"position":' + pos + '}}';
    return JSON.parse(json) as ESObject;
  }

  /**
   * 是否应当**忽略**这次 resize 请求。两种情况：
   *
   * 1. **最大化 / 全屏期间**：系统本来就会拒绝（`CheckAndModifyWindowRect failed`），
   *    而且这些请求会污染系统记住的"还原几何" —— 退出最大化时回到的就不是原样了；
   * 2. **≤2 像素的微调**：上游有一段 Linux 专用 workaround
   *    （`linuxWindowRestoreTransparentBg`：innerSize ±1 再 setSize），
   *    目的是复位透明背景 —— 那是 Linux/WebKit 的问题，鸿蒙上只会把窗口
   *    越推越歪（真机日志里的 2089↔2090、3119↔3120、3121↔2081 全是它）。
   */
  private skipResizeWhileToggled(win: window.Window, width: number, height: number): boolean {
    if (this.maximizedHint || this.fullscreenHint) {
      this.onDiag('window set_size skipped (' + String(width) + 'x' + String(height) +
        '): maximized=' + String(this.maximizedHint) + ' fullscreen=' + String(this.fullscreenHint));
      return true;
    }
    try {
      const rect = win.getWindowProperties().windowRect;
      if (Math.abs(rect.width - width) <= 2 && Math.abs(rect.height - height) <= 2) {
        this.onDiag('window set_size skipped (nudge ' + String(width) + 'x' + String(height) + ')');
        return true;
      }
    } catch (error) {
      // 读不到矩形就不跳过
    }
    return false;
  }

  /**
   * `resize()` 带退避重试。
   *
   * 起因（2026-10-10 真机日志）：应用在切换最大化/全屏后 **5 毫秒**就来设尺寸 ——
   *   16:07:28.391 toggle_maximize: was=false
   *   16:07:28.396 window set_size -> 2089x1393
   *   16:07:28.397 resize failed: This window state is abnormal.
   *                   Window resize failed: CheckAndModifyWindowRect failed
   * 窗口在切换途中，系统会拒绝改动。**这不是错误，是时序** —— 退避重试即可；
   * 否则应用想恢复的尺寸永远落不了地，窗口就停在切换后的位置/比例（用户看到的现象）。
   */
  private resizeWithRetry(win: window.Window, width: number, height: number, attempt: number): void {
    win.resize(width, height).then(() => {
      // 记下结果矩形：万一 resize 会顺手挪动窗口（系统行为），这条日志能一眼看出来。
      try {
        const rect = win.getWindowProperties().windowRect;
        this.onDiag('resize ok -> rect=' + String(rect.left) + ',' + String(rect.top) +
          ' ' + String(rect.width) + 'x' + String(rect.height) + ' (attempt ' + String(attempt) + ')');
      } catch (error) {
        // 忽略
      }
    }).catch((error: ESObject) => {
      const text = String(error);
      if (text.indexOf('CheckAndModifyWindowRect') >= 0 && attempt < 5) {
        setTimeout(() => {
          this.resizeWithRetry(win, width, height, attempt + 1);
        }, 120 * (attempt + 1));
        return;
      }
      this.onDiag('resize failed (attempt ' + String(attempt) + '): ' + text);
    });
  }

  /** `moveWindowTo()` 带退避重试（与 resize 同理：切换途中会被拒）。 */
  private moveWithRetry(win: window.Window, x: number, y: number, attempt: number): void {
    win.moveWindowTo(x, y).catch((error: ESObject) => {
      const text = String(error);
      if (attempt < 5) {
        setTimeout(() => {
          this.moveWithRetry(win, x, y, attempt + 1);
        }, 120 * (attempt + 1));
        return;
      }
      this.onDiag('moveWindowTo failed (attempt ' + String(attempt) + '): ' + text);
    });
  }

  /**
   * ⚠️ **不要用 `resize()` 自己实现最大化/还原。**
   *
   * 2026-10-10 实测（真机日志）：
   *   restore resize failed: This window state is abnormal.
   *     Window resize failed: CheckAndModifyWindowRect failed
   * 一旦窗口处于最大化 / 边到边（本移植 2in1 即如此），系统会**直接拒绝** resize；
   * 而应用自己本来就会用 `set_size` 管理并恢复窗口尺寸 —— 我们再插一套几何逻辑，
   * 结果就是两边互相打架、两个方向都坏（用户原话："以前都没问题，怎么出问题了"）。
   *
   * 结论：几何只走系统 API（`maximize()` / `recover()`），我们只负责**记住方向**。
   */

  /**
   * "是否已最大化"**只认我们自己做过什么**（`maximizedHint`），不再用几何猜。
   *
   * 为什么放弃几何（2026-10-10 真机 + 医生页自动用例实证）：
   *   - 2in1 上应用**启动时窗口就是最大化的**（系统默认），几何判据会把它当成
   *     "已最大化" → 第一次点按钮就变成 recover() → 窗口被还原成系统默认的普通窗口
   *     （3120x1903 @589,75）→ 用户看到"大小跟最大化前不一致、位置也不对"；
   *   - 而那个普通窗口仍然 ≥88% 屏宽 → 几何判定继续说"已最大化" →
   *     `start_dragging` 被自己的守卫拦住 → "拖不动"。
   * 状态与几何是两件事：边到边/满屏 ≠ 已最大化。
   *
   * 唯一一次例外：**首次**解析时与系统对齐一次（启动即最大化是系统给的既成事实，
   * 我们要如实承认它，否则第一次点击会变成"再最大化一次"的空操作）。
   */
  private resolveMaximized(win: window.Window): boolean {
    if (!this.osStateSynced) {
      this.osStateSynced = true;
      try {
        const rect = win.getWindowProperties().windowRect;
        const screen = display.getDefaultDisplaySync();
        if (rect.width >= screen.width * GEOMETRY_RATIO && rect.height >= screen.height * GEOMETRY_RATIO) {
          this.maximizedHint = true;
          this.onDiag('window state synced from OS: maximized (startup)');
        }
      } catch (error) {
        this.onDiag('window state sync failed: ' + String(error));
      }
    }
    return this.maximizedHint;
  }

  /** 系统状态只在首次解析时对齐一次，之后完全由我们自己的动作决定。 */
  private osStateSynced: boolean = false;

}
