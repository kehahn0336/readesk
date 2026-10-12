import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { ReadestBridge } from '../bridge/ReadestBridge';

const DOMAIN = 0x5246;
const TAG = 'ReadestOHOS';

interface BrowserDownloadInfo {
  url: string;
  filename: string;
  path: string;
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private browserController: webview.WebviewController = new webview.WebviewController();
  private bridge: ReadestBridge = new ReadestBridge();
  // 系统栏可见时，内置浏览器覆盖层需要避让的顶部高度（vp），由桥侧写入。
  @StorageProp('readestTopSafe') private topSafe: number = 0;
  @State private pageReady: boolean = false;
  @State private showBrowser: boolean = false;
  @State private browserUrl: string = '';
  @State private browserClipLabel: string = 'Clip Page';
  @State private browserCloseLabel: string = 'Close';
  /**
   * Import status shown in the browser toolbar, mirroring upstream's injected
   * chrome (`web_browser_chrome.js`): five states pushed through
   * `setStatus()` and rendered as a pill in the browser chrome, not as a page.
   */
  @State private browserStatusState: string = '';
  @State private browserStatusFile: string = '';
  /** Upstream hides the pill 8s after a terminal state. */
  private browserStatusHideTimer: number = 0;
  private browserResolve: ((html: string) => void) | null = null;
  private browserDownloadDelegate: webview.WebDownloadDelegate | null = null;
  private browserDownloadItems: Map<string, BrowserDownloadInfo> = new Map();
  /**
   * Downloads in flight for the CURRENT browser session. Session-scoped on
   * purpose: a URL that failed in a previous session must be retryable, which
   * it would not be if this set outlived the overlay.
   */
  private browserBookDownloading: Set<string> = new Set();
  /** Sandbox path of the download awaiting an import confirmation. */
  private lastBookDownloadPath: string = '';
  /**
   * Intermediates of the current download (download file + unpacked dir) plus
   * the moment the import finished. Deleted on the configurable delay below;
   * `onPageShow` additionally sweeps leftovers older than a day.
   */
  private pendingDownloadPath: string = '';
  private pendingArchiveDir: string = '';
  private pendingCleanupTimer: number = 0;
  /**
   * True from the moment the in-app browser starts a book download until the
   * webapp reports a terminal import state (`added`/`failed`/`unsupported`) or
   * the overlay is closed. It must outlive `browserBookDownload()`, because the
   * import report arrives only after that function returns.
   */
  private bookImportAwaitingReport: boolean = false;

  /**
   * Once the webapp reports a terminal import state the download file and its
   * unpacked tree are no longer needed (the book itself is copied into
   * Books/<hash>/). Wait a beat so nothing can still be reading them, then drop
   * both. `added` is the normal path; `failed` cleans up immediately because
   * nothing will consume those bytes.
   */
  private scheduleBrowserCacheCleanup(immediate: boolean): void {
    if (this.pendingDownloadPath.length === 0 && this.pendingArchiveDir.length === 0) return;
    if (this.pendingCleanupTimer !== 0) {
      clearTimeout(this.pendingCleanupTimer);
      this.pendingCleanupTimer = 0;
    }
    const delay = immediate ? 0 : 5000;
    this.pendingCleanupTimer = setTimeout(() => {
      this.pendingCleanupTimer = 0;
      if (this.pendingDownloadPath.length > 0) {
        this.bridge.removePath(this.pendingDownloadPath);
        hilog.info(DOMAIN, TAG, 'cache cleanup: removed %{public}s', this.pendingDownloadPath);
        this.pendingDownloadPath = '';
      }
      if (this.pendingArchiveDir.length > 0) {
        this.bridge.removePath(this.pendingArchiveDir);
        this.pendingArchiveDir = '';
      }
    }, delay);
  }

  /**
   * Sweep browser-download leftovers older than a day. Runs per page show so a
   * download interrupted by a crash, an uninstall-free upgrade or a killed
   * overlay cannot accumulate forever.
   */
  private sweepStaleBrowserCache(): void {
    const root = this.bridge.browserCacheRoot();
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    const downloads = this.bridge.listCacheDir(root + '/web-downloads');
    let removed = 0;
    for (let i = 0; i < downloads.length; i++) {
      const full = root + '/web-downloads/' + downloads[i];
      if (this.bridge.pathMtimeMs(full) < cutoff) {
        this.bridge.removePath(full);
        removed++;
      }
    }
    const entries = this.bridge.listCacheDir(root);
    for (let i = 0; i < entries.length; i++) {
      const name = entries[i];
      if (name.indexOf('web-archive-') !== 0) continue;
      const full = root + '/' + name;
      if (this.bridge.pathMtimeMs(full) < cutoff) {
        this.bridge.removePath(full);
        removed++;
      }
    }
    if (removed > 0) {
      hilog.info(DOMAIN, TAG, 'stale browser cache swept: %{public}d entries', removed);
    }
  }

  onPageShow(): void {
    this.sweepStaleBrowserCache();
  }

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.bridge.setContext(context);
    // 注意：这里**不**做任何书库根目录重定向。上一轮的“自定义书库目录”实验正是把根
    // 指到别的目录，才让 25 本历史书看起来“消失”。新方案（M4）必须带迁移与回退。
    this.bridge.setController(this.controller);
    this.bridge.initWindow();
    this.bridge.setBrowserOpener((url: string, clipLabel: string, closeLabel: string) =>
      this.openBrowser(url, clipLabel, closeLabel));
    // Let bridge-level `set_web_browser_status` calls drive the download page:
    // once the webapp reports `added`, the browser overlay closes itself.
    this.bridge.setImportStatusSink((state: string, filename: string) =>
      this.browserImportStatus(state, filename));
  }

  // Called by the bridge (open_web_browser): show the in-app browser and hand
  // back the clipped page HTML when the user taps Clip Page ('' on close).
  openBrowser(url: string, clipLabel: string, closeLabel: string): Promise<string> {
    hilog.info(DOMAIN, TAG, 'in-app browser open url=%{public}s', url);
    this.bridge.diag('browser open url=' + url);
    // A fresh browser session starts with a clean download flow: no timer, no
    // leftover in-flight URL, and above all no "awaiting report" flag that a
    // stale webapp report from a previous session could act on.
    this.browserBookDownloading.clear();
    this.bookImportAwaitingReport = false;
    this.lastBookDownloadPath = '';
    return new Promise<string>((resolve: (html: string) => void) => {
      this.browserResolve = resolve;
      this.browserUrl = url;
      this.browserClipLabel = clipLabel;
      this.browserCloseLabel = closeLabel;
      this.showBrowser = true;
    });
  }

  /**
   * Tear the browser overlay down and drop every piece of download-flow state
   * with it, so a later browser session (or a download that finishes after the
   * user closed the overlay) cannot touch a stale page or fire a stale timer.
   */
  private finishBrowser(html: string): void {
    const r = this.browserResolve;
    this.browserResolve = null;
    this.showBrowser = false;
    this.bookImportAwaitingReport = false;
    this.browserBookDownloading.clear();
    this.lastBookDownloadPath = '';
    this.clearBrowserStatus();
    if (r) {
      r(html);
    }
  }

  /**
   * Drop the in-flight URL marker. Note this does NOT end the "awaiting import
   * report" state: that is exactly the bug that made the overlay hang, because
   * the report arrives after this function has already run.
   */
  private finishBookDownload(url: string): void {
    this.browserBookDownloading.delete(url);
  }

  /**
   * Book-archive download interception (roadmap #3).
   *
   * This app's Web component is CEF-backed and does NOT surface ArkWeb's
   * WebDownloadDelegate for page downloads (verified on device: the
   * delegate callbacks never fire, with or without a `download`
   * attribute), so downloads are taken over here instead: the navigation
   * is answered with a local "downloading" page while the file is fetched
   * through the platform HTTP stack and saved into the sandbox, then
   * `web-browser-download` is emitted for the webapp to import.
   *
   * Only non-displayable book formats are intercepted — text/html/md keep
   * their normal in-browser rendering. `onInterceptRequest` itself DOES
   * fire on this CEF Web (the main Web already relies on it).
   */
  private browserInterceptBookDownload(requestUrl: string): WebResourceResponse | undefined {
    if (!/\.(epub|mobi|azw3?|fb2|cbz|zip|pdf)(\?|#|$)/i.test(requestUrl)) return undefined;
    if (this.browserBookDownloading.has(requestUrl)) {
      // A real duplicate while the first attempt is still running (or its book
      // is still being imported): report the state instead of starting twice.
      // Failed downloads are removed from this set, so a retry re-enters below.
      return this.browserDownloadPlaceholderPage(this.bridge.suggestedFileName(requestUrl), true);
    }
    this.browserBookDownloading.add(requestUrl);
    this.bookImportAwaitingReport = true;
    this.showBrowserStatus('downloading', this.bridge.suggestedFileName(requestUrl));
    hilog.info(DOMAIN, TAG, 'browser book download intercept: %{public}s', requestUrl);
    this.bridge.diag('browser intercept url=' + requestUrl);
    void this.browserBookDownload(requestUrl);
    return this.browserDownloadPlaceholderPage(this.bridge.suggestedFileName(requestUrl), false);
  }

  /**
   * Placeholder document for an intercepted book navigation.
   *
   * Upstream never sees this: its native `on_download` hook lets the browser
   * carry on downloading and only pushes a status into the chrome. This CEF
   * Web does not surface download events at all, so `onInterceptRequest` has
   * to answer the navigation itself — the page is consumed as a side effect.
   * The link's own state (downloading/importing/added/…) therefore lives in
   * the browser toolbar, exactly where upstream puts it, and this document
   * only says that the tap was received.
   */
  private browserDownloadPlaceholderPage(filename: string, retry: boolean): WebResourceResponse {
    const html = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1"></head>' +
      '<body style="font-family:sans-serif;padding:24px;color:#666">' +
      '<h3>' + (retry ? '正在重试下载' : '正在下载') + '</h3>' +
      '<p>' + filename + '</p>' +
      '<p>下载完成后会自动导入书库，状态显示在顶部工具栏。</p></body></html>';
    const response = new WebResourceResponse();
    response.setResponseHeader([
      { headerKey: 'Content-Type', headerValue: 'text/html; charset=utf-8' },
      { headerKey: 'Cache-Control', headerValue: 'no-store' },
    ]);
    response.setResponseData(html);
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    return response;
  }

  /**
   * Update the browser toolbar status line. Mirrors upstream's `setStatus`:
   * `added`/`failed`/`unsupported` hide themselves after 8s, `importing` and
   * the placeholder states stay until the next one arrives, and only `added`
   * with a book hash offers [Open].
   */
  private showBrowserStatus(state: string, filename: string): void {
    this.browserStatusState = state;
    this.browserStatusFile = filename;
    if (this.browserStatusHideTimer !== 0) {
      clearTimeout(this.browserStatusHideTimer);
      this.browserStatusHideTimer = 0;
    }
    if (state === 'downloading' || state === 'importing') return;
    this.browserStatusHideTimer = setTimeout(() => {
      this.browserStatusHideTimer = 0;
      this.clearBrowserStatus();
    }, 8000);
  }

  private clearBrowserStatus(): void {
    if (this.browserStatusHideTimer !== 0) {
      clearTimeout(this.browserStatusHideTimer);
      this.browserStatusHideTimer = 0;
    }
    this.browserStatusState = '';
    this.browserStatusFile = '';
  }

  /** Localised label for a status state (upstream: WebBrowserLabelKey). */
  private browserStatusLabel(state: string): string {
    switch (state) {
      case 'downloading': return '下载中';
      case 'importing': return '正在导入';
      case 'added': return '已加入书库';
      case 'failed': return '导入失败';
      case 'unsupported': return '不是支持的书籍格式';
      default: return state;
    }
  }

  /**
   * Bridge hook: the webapp relays the browser download status it receives
   * (`set_web_browser_status`). These are the same five states upstream renders
   * in its browser chrome (downloading/importing/added/failed/unsupported), and
   * like upstream this only updates the page -- closing the browser stays a
   * user action.
   */
  browserImportStatus(state: string, filename: string): void {
    // 先记再判：这样能区分"webapp 根本没上报"与"上报到了但浮层已关被丢弃"。
    this.bridge.diag('browser import report state=' + state + ' file=' + filename +
      ' overlayOpen=' + String(this.showBrowser) + ' awaiting=' + String(this.bookImportAwaitingReport));
    if (!this.showBrowser) return;
    if (state !== 'added' && !this.bookImportAwaitingReport) return;
    if (state === 'downloading') {
      this.showBrowserStatus('downloading', filename);
    } else if (state === 'importing') {
      this.showBrowserStatus('importing', filename);
    } else if (state === 'added') {
      // Upstream: the chrome shows "Added to library" + [Open]; the browser
      // stays open and the user decides whether to read or keep browsing.
      this.bookImportAwaitingReport = false;
      this.browserBookDownloading.clear();
      this.showBrowserStatus('added', filename);
      this.scheduleBrowserCacheCleanup(false);
    } else if (state === 'failed') {
      this.bookImportAwaitingReport = false;
      this.browserBookDownloading.clear();
      this.showBrowserStatus('failed', filename);
      this.scheduleBrowserCacheCleanup(true);
    } else if (state === 'unsupported') {
      this.bookImportAwaitingReport = false;
      this.showBrowserStatus('unsupported', filename);
    }
  }

  private async browserBookDownload(url: string): Promise<void> {
    const filename = this.bridge.suggestedFileName(url);
    const path = this.bridge.browserDownloadsDir() + '/' + filename;
    let succeeded = false;
    try {
      await this.bridge.downloadToFile(url, path);
      let bytes = 0;
      try {
        bytes = fs.statSync(path).size;
      } catch (_error) {
        bytes = 0;
      }
      hilog.info(DOMAIN, TAG, 'browser book download done: %{public}s (%{public}d bytes)', filename, bytes);
      this.bridge.diag('browser download done file=' + filename + ' bytes=' + String(bytes) + ' path=' + path);
      this.lastBookDownloadPath = path;
      this.pendingDownloadPath = path;
      this.pendingArchiveDir = this.bridge.webBrowserArchiveDir(path);
      this.showBrowserStatus('importing', filename);
      this.bridge.emitWebBrowserDownload(url, path, filename, true, '');
      // No close timer on purpose (upstream behaviour): the browser stays open
      // while the webapp reports `importing` then `added` through
      // set_web_browser_status, and only the user closes it.
      succeeded = true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'browser book download failed: %{public}s', String(error));
      this.bridge.diag('browser download FAILED file=' + filename + ' err=' + String(error));
      this.bookImportAwaitingReport = false;
      this.showBrowserStatus('failed', filename);
      this.bridge.emitWebBrowserDownload(url, '', filename, false, String(error));
    } finally {
      // Success keeps the URL in flight: it still has to survive the webapp
      // import, and `finishBookDownload` runs on the terminal import report.
      // A FAILED download drops it now so the same link can be retried.
      if (!succeeded) {
        this.finishBookDownload(url);
      }
    }
  }

  /**
   * In-app browser download support (roadmap #3). ArkWeb hands us each
   * download via WebDownloadDelegate: we save it into the app sandbox
   * (cacheDir/web-downloads) and forward a `web-browser-download` event to
   * the main webapp, whose useWebBrowserDownloads imports it (unzipping
   * `.zip` archives through extract_web_browser_archive).
   *
   * Registered from onControllerAttached so the controller is bound to the
   * Web component already (setDownloadDelegate throws 17100001 otherwise).
   * A download in flight dies with the browser overlay (the Web unmounts);
   * surviving that would need @ohos.request.agent instead.
   */
  private attachBrowserDownloadDelegate(): void {
    if (this.browserDownloadDelegate) return;
    const delegate = new webview.WebDownloadDelegate();
    const items = this.browserDownloadItems;
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      try {
        const filename = item.getSuggestedFileName() || 'download.bin';
        const path = this.bridge.browserDownloadsDir() + '/' + filename;
        item.start(path);
        const info: BrowserDownloadInfo = { url: item.getUrl() || '', filename: filename, path: path };
        items.set(item.getGuid(), info);
        hilog.info(DOMAIN, TAG, 'browser download started: %{public}s', filename);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'browser download start failed: %{public}s', String(error));
      }
    });
    delegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      const info = items.get(item.getGuid());
      items.delete(item.getGuid());
      this.bridge.emitWebBrowserDownload(info ? info.url : '', info ? info.path : '', info ? info.filename : '', true, '');
    });
    delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      const info = items.get(item.getGuid());
      items.delete(item.getGuid());
      this.bridge.emitWebBrowserDownload(info ? info.url : '', '', info ? info.filename : '', false,
        'download failed, error code: ' + String(item.getLastErrorCode()));
    });
    this.browserDownloadDelegate = delegate;
    try {
      this.browserController.setDownloadDelegate(delegate);
      hilog.info(DOMAIN, TAG, 'browser download delegate attached');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setDownloadDelegate failed: %{public}s', String(error));
    }
  }

  private clipBrowserPage(): void {
    // Send the page HTML to native through the javaScriptProxy (the same channel
    // the app's own Web uses, which round-trips CJK correctly); native writes it
    // to a temp file and we read it back as UTF-8. This avoids runJavaScript's
    // lossy string return (which mangles non-ASCII).
    hilog.info(DOMAIN, TAG, 'in-app browser clip pressed');
    this.browserController.runJavaScript(
      "(() => { try { if (!window.__readestClip || !window.__readestClip.saveBrowserClipHtml) return 'NO_PROXY'; window.__readestClip.saveBrowserClipHtml(document.documentElement.outerHTML); return 'OK'; } catch (e) { return 'ERR:' + e; } })()"
    )
      .then((_r: string) => {
        hilog.info(DOMAIN, TAG, 'in-app browser clip js=%{public}s', _r);
        let html = '';
        try {
          html = this.bridge.readBrowserClip();
        } catch (error) {
          html = '';
        }
        this.finishBrowser(html);
      })
      .catch((error: Object) => {
        hilog.warn(DOMAIN, TAG, 'clip page failed: %{public}s', String(error));
        this.finishBrowser('');
      });
  }

  build() {
    Stack() {
      Column() {
        Web({
          src: 'http://appassets.local/index.html',
          controller: this.controller,
        })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .databaseAccess(true)
          .imageAccess(true)
          .javaScriptProxy({
            object: this.bridge,
            name: '__readestHost',
            methodList: this.bridge.methodList(),
            controller: this.controller,
          })
          .onInterceptRequest((event) => {
            return this.bridge.interceptRequest(event.request);
          })
          .onPageEnd(() => {
            this.pageReady = true;
            hilog.info(DOMAIN, TAG, 'web page loaded');
          })
          .onConsole((event) => {
            const msg = event.message.getMessage();
            hilog.info(DOMAIN, TAG, 'console: %{public}s', msg);
            this.bridge.diag('console: ' + msg.slice(0, 400));
            return false;
          })
      }
      .width('100%')
      .height('100%')

      if (this.showBrowser) {
        Column() {
          Row() {
            Button('‹')
              .fontSize(22)
              .backgroundColor('#00000000')
              .fontColor('#222222')
              .onClick(() => {
                try { this.browserController.backward(); } catch (error) { }
              })
            Button('›')
              .fontSize(22)
              .backgroundColor('#00000000')
              .fontColor('#222222')
              .onClick(() => {
                try { this.browserController.forward(); } catch (error) { }
              })
            Button('⟳')
              .fontSize(18)
              .backgroundColor('#00000000')
              .fontColor('#222222')
              .onClick(() => {
                try { this.browserController.refresh(); } catch (error) { }
              })
            Blank()
            Button(this.browserClipLabel)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor('#222222')
              .onClick(() => this.clipBrowserPage())
            Button(this.browserCloseLabel)
              .fontSize(15)
              .backgroundColor('#00000000')
              .fontColor('#222222')
              .margin({ left: 8 })
              .onClick(() => {
                // Explicit user close always wins: drop the flow and any timer.
                hilog.info(DOMAIN, TAG, 'browser closed by user');
                this.finishBrowser('');
              })
          }
          .width('100%')
          .height(52)
          .padding({ left: 8, right: 8 })
          .backgroundColor('#F5F5F5')

          // Import status line — the equivalent of upstream's injected browser
          // chrome pill (`web_browser_chrome.js`): status text plus, on
          // `added`, an [Open] button for the freshly imported book.
          if (this.browserStatusState.length > 0) {
            Row() {
              Text(this.browserStatusLabel(this.browserStatusState))
                .fontSize(13)
                .fontColor('#333333')
              if (this.browserStatusFile.length > 0) {
                Text(' · ' + this.browserStatusFile)
                  .fontSize(13)
                  .fontColor('#666666')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              } else {
                Blank().layoutWeight(1)
              }
            }
            .width('100%')
            .height(40)
            .padding({ left: 12, right: 8 })
            .backgroundColor('#EDEDED')
          }

          Web({
            src: this.browserUrl,
            controller: this.browserController,
          })
            .width('100%')
            .height('100%')
            .onControllerAttached(() => {
              hilog.info(DOMAIN, TAG, 'browser controller attached');
              this.attachBrowserDownloadDelegate();
            })
            .onInterceptRequest((event) => {
              return this.browserInterceptBookDownload(event.request.getRequestUrl());
            })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(true)
            .databaseAccess(true)
            .imageAccess(true)
            .javaScriptProxy({
              object: this.bridge,
              name: '__readestClip',
              methodList: ['saveBrowserClipHtml'],
              controller: this.browserController,
            })
            .onConsole((event) => {
              hilog.info(DOMAIN, TAG, 'browser console: %{public}s', event.message.getMessage());
              return false;
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#FFFFFF')
        // 内置浏览器是 ArkTS 覆盖层：状态栏可见时必须给它顶部避让，
        // 否则地址栏与按钮会被状态栏压住 —— 用户反馈的「浏览器导入时菜单不能用」。
        .padding({ top: this.topSafe })
      }
    }
    .width('100%')
    .height('100%')
  }
}
