import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReadestBridge } from '../bridge/ReadestBridge';

const DOMAIN = 0x5245;
const TAG = 'ReadestOHOS';
const DECOR_HEIGHT_PX = 0;

export default class EntryAbility extends UIAbility {
  /** 启动页；默认 webapp 宿主，want 参数 page=doctor 时切到自检页。 */
  private startPage: string = 'pages/Index';

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.consumeWant(want);
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(error));
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.consumeWant(want);
  }

  private consumeWant(want: Want): void {
    if (want.uri && want.uri.length > 0) {
      ReadestBridge.addPendingOpenUrl(want.uri);
      hilog.info(DOMAIN, TAG, 'pending open uri: %{public}s', want.uri);
    }
    // M3 起默认启动页是 webapp 宿主，医生页不再有 UI 入口；用 want 参数把它调起来，
    // 交付脚本与 CI 才能自动跑自检：aa start ... --ps page doctor
    const params: Record<string, Object> | undefined = want.parameters;
    if (params && String(params.page) === 'doctor') {
      this.startPage = 'pages/Doctor';
      hilog.info(DOMAIN, TAG, 'start page overridden to doctor');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Let the system WM remember the last non-maximized window rect. The skill
    // explicitly says not to gate this behind isWindowRectAutoSave(): just try
    // it and only fall back on 801.
    try {
      windowStage.setWindowRectAutoSave(true);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setWindowRectAutoSave failed: %{public}s', String(error));
    }
    // 桥只有 context（没有 WindowStage），而 `plugin:window|*` 走同步路径要求立刻拿到窗口，
    // 所以由这里用 getMainWindowSync() 取一次放进 AppStorage，窗口域再从那里取用。
    try {
      AppStorage.setOrCreate('readestMainWindow', windowStage.getMainWindowSync());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'share main window failed: %{public}s', String(error));
    }
    windowStage.loadContent(this.startPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.applyDesktopWindow(windowStage);
    });
  }

  /**
   * 窗口策略：**按设备形态分流**（2026-10-11）。
   *
   * - **2in1（PC）**：保持既有的沉浸式行为，逻辑一字未改 —— 自绘标题栏 + 边到边，
   *   实测该形态 `avoid.top = 0`，系统栏不占位，因此不会冲突。
   * - **tablet / phone**：只隐藏系统装饰，**不调用 `setWindowLayoutFullScreen(true)`** ——
   *   让系统自己为状态栏留位（平板实测 `avoid.top = 104px ≈ 44vp`）。
   *   这样自绘标题栏落在状态栏下方，既不被遮挡，也不会出现"系统标题栏 + 自绘标题栏"双栏。
   *
   * 为什么不能继续用"全屏 + 自行避让"：我们的界面是 WebView，官方技能的
   * `expandSafeArea` / HDS 组件都用不上，避让高度必须另想办法下发给网页；
   * 而"不全屏"这条路由系统直接完成避让，风险最低（见 notes/multidevice-adaptation-analysis.md）。
   */
  private applyDesktopWindow(windowStage: window.WindowStage): void {
    try {
      const deviceType: string = String(deviceInfo.deviceType);
      // 所有形态统一沉浸（2026-10-11 第二轮）：移动端的「状态栏露出/隐藏」不再靠
      // 退出全屏，而由 native-bridge 的 set_system_ui_visibility + 网页按状态栏高度撑开实现。
      if (deviceType === '2in1' || deviceType === 'tablet' || deviceType === 'phone') {
        const win: window.Window = windowStage.getMainWindowSync();
        win.setWindowDecorVisible(false);
        // Readest draws and owns its own minimize/maximize/close controls.
        win.setWindowTitleButtonVisible(false, false, false);
        win.setWindowDecorHeight(DECOR_HEIGHT_PX);
        win.setWindowLayoutFullScreen(true);
        // Let the Web toolbar own drag/double-click, because the hidden title bar
        // would otherwise swallow pointer events at the top of the window.
        win.setWindowTitleMoveEnabled(false);
        AppStorage.setOrCreate('readestTitleBtnWidth', 0);
        AppStorage.setOrCreate('readestTitleBtnCenter', 0);
        win.on('windowTitleButtonRectChange', (rect: window.TitleButtonRect) => {
          AppStorage.setOrCreate('readestTitleBtnWidth', rect.width);
          AppStorage.setOrCreate('readestTitleBtnCenter', rect.top + rect.height / 2);
        });
        hilog.info(DOMAIN, TAG, 'window policy: %{public}s immersive (layout full screen ON)', deviceType);
      }
      windowStage.removeStartingWindow();
      hilog.info(DOMAIN, TAG, 'window stage ready');
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'desktop window setup failed: %{public}s', JSON.stringify(e));
    }
  }
}
