/**
 * 桥自检页（doctor）。入口：main_pages.json 里的 pages/Doctor；M3 起默认启动页是 webapp 宿主。
 *
 * 这里刻意只做一件事——把真实 webapp 的调用路径跑通：页面 `doctor.html` 通过
 * `readest-bridge.js` 的 `__TAURI_INTERNALS__.invoke` 打桥，桥把结果回给页面。
 * 因此自检**不经过任何旁路**，绿了才说明 fs/path/window 三个域真的可用。
 *
 * M3 会把本页换成 webapp 宿主（旧工程的浏览器浮层实现留档在 reference/Index-browser-overlay.ets）。
 */
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReadestBridge } from '../bridge/ReadestBridge';

const DOMAIN = 0x5246;
const TAG = 'ReadestOHOS';

@Entry
@Component
struct Doctor {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ReadestBridge = new ReadestBridge();
  @State summary: string = '正在运行桥自检…';
  @State failed: number = 0;
  @State passed: number = 0;
  @State lastDetail: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.bridge.setContext(context);
    this.bridge.setController(this.controller);
    this.bridge.diag('doctor page start');
  }

  aboutToDisappear(): void {
    this.bridge.closeAll();
  }

  /** 从页面 console 里汇总自检结果（页面自己也会把结果渲染到屏幕上）。 */
  private ingest(message: string): void {
    if (message.indexOf('DOCTOR|PASS|') === 0 || message.indexOf('DOCTOR|FAIL|') === 0) {
      const parts = message.split('|');
      const ok = parts[1] === 'PASS';
      if (ok) this.passed += 1;
      else {
        this.failed += 1;
        this.lastDetail = (parts[2] || '') + ' → ' + (parts.slice(3).join('|') || '');
      }
      this.summary = `${this.passed} 通过 / ${this.failed} 失败`;
      return;
    }
    if (message.indexOf('DOCTOR|REPORT|') === 0) {
      this.summary = `${this.passed} 通过 / ${this.failed} 失败 · 报告已写入`;
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.failed === 0 && this.passed > 0 ? '✓ ' : (this.failed > 0 ? '✗ ' : ''))
          .fontSize(18)
          .fontColor(this.failed > 0 ? '#ff6b6b' : '#3ddc84')
        Text(this.summary)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('重跑')
          .fontSize(14)
          .height(32)
          .onClick(() => {
            this.passed = 0;
            this.failed = 0;
            this.summary = '正在运行桥自检…';
            this.lastDetail = '';
            this.controller.runJavaScript('window.__runDoctor && window.__runDoctor()');
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      if (this.lastDetail.length > 0) {
        Text(this.lastDetail)
          .fontSize(12)
          .fontColor('#ff9f9f')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Web({ src: $rawfile('doctor.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .javaScriptProxy({
          object: this.bridge,
          name: '__readestHost',
          methodList: this.bridge.methodList(),
          controller: this.controller,
        })
        .onConsole((event) => {
          const msg = event.message.getMessage();
          hilog.info(DOMAIN, TAG, 'console: %{public}s', msg);
          this.ingest(msg);
          // 自检细节全部落盘：hilog 在本应用上不稳定，文件才是可靠证据。
          this.bridge.diag('console: ' + msg.slice(0, 400));
          return false;
        })
        .onPageEnd(() => {
          this.bridge.initWindow();
          this.bridge.diag('doctor page loaded');
        })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#14161a')
  }
}
