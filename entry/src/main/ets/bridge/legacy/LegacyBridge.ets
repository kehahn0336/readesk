/**
 * 旧工程的桥实现（**原样保留，仅重命名类**）。
 *
 * 用途：M3 期间作为"尚未迁移域"的实现来源（app/event/turso/http/ws/dialog/tts/browser 等）。
 * 新核心 `../ReadestBridge` 会**先**拦截 plugin:fs / plugin:path / plugin:window 三个已重写域，
 * 因此本文件里那三个域的实现是**不可达的死代码**（重写期内暂留作对照，各域独立验证通过后逐个删除）。
 *
 * 纪律：不要在这里新增功能；新功能一律进 `domains/`，迁完一个域就删掉这里的对应实现。
 */
import { abilityAccessCtrl, common, OpenLinkOptions, Permissions } from '@kit.AbilityKit';
// URI→真实路径的**单一来源**（BridgeProtocol.uriToPath）。本文件曾自带一份实现，
// 与 PathDomain.physical() 各自演化 —— 结果一处漏了百分号解码，
// 导致"目录对话框回可读路径"的判定一直 ENOENT、界面长期显示编码后的 URI。
import { uriToPath } from '../BridgeProtocol';
import { window, display } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs, fileShare, picker, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { BusinessError, pasteboard, zlib } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import webSocket from '@ohos.net.webSocket';

const DOMAIN = 0x5245;
const TAG = 'LegacyBridge';

const BD_TEMP = 12;
const BD_APP_CONFIG = 13;
const BD_APP_DATA = 14;
const BD_APP_LOCAL_DATA = 15;
const BD_APP_CACHE = 16;
const BD_APP_LOG = 17;

class TtsVoiceInfo {
  id: string;
  name: string;
  lang: string;
  disabled: boolean;

  constructor(id: string, name: string, lang: string, disabled: boolean) {
    this.id = id;
    this.name = name;
    this.lang = lang;
    this.disabled = disabled;
  }
}

class TtsVoicesResult {
  voices: Array<TtsVoiceInfo>;

  constructor(voices: Array<TtsVoiceInfo>) {
    this.voices = voices;
  }
}

class TtsInitResult {
  success: boolean;

  constructor(success: boolean) {
    this.success = success;
  }
}

class TtsPlayoutItem {
  session: number;
  index: number;
  filePath: string;
  gapMs: number;
  durationMs: number;
  fd: number;
  player: media.AVPlayer | null;
  started: boolean;
  // Media Overlay single-file mode: emit 'ended' on completion (no queue
  // advance). Edge TTS chunk queue leaves this false.
  singleFile: boolean;
  // Whether the native side owns filePath and should unlink it on release.
  // Edge TTS chunk files are written here (owned); Media Overlay files are
  // owned by the JS side (staged temp / Books/<hash>) - never unlink those.
  ownsFile: boolean;

  constructor(session: number, index: number, filePath: string, gapMs: number) {
    this.session = session;
    this.index = index;
    this.filePath = filePath;
    this.gapMs = gapMs;
    this.durationMs = 0;
    this.fd = -1;
    this.player = null;
    this.started = false;
    this.singleFile = false;
    this.ownsFile = true;
  }
}

interface WebBrowserPageObj {
  url: string;
  html: string;
}
interface WebBrowserResultObj {
  page: WebBrowserPageObj;
}
/** Encoded bytes plus the number of valid bytes at their head. */
interface SizedBytes {
  bytes: Uint8Array;
  size: number;
}

interface WriteRequest {
  path: string;
  baseDir: number;
}

interface BrowserResourceObj {
  url: string;
  status: number;
  contentType: string;
  body: string;
}

class WsConn {
  id: number;
  socket: webSocket.WebSocket;
  channelId: number;
  index: number;

  constructor(id: number, socket: webSocket.WebSocket, channelId: number) {
    this.id = id;
    this.socket = socket;
    this.channelId = channelId;
    this.index = 0;
  }
}

class ReadestTtsListener implements textToSpeech.SpeakListener {
  private bridge: LegacyBridge;

  constructor(bridge: LegacyBridge) {
    this.bridge = bridge;
  }

  onStart(requestId: string, _response: textToSpeech.StartResponse): void {
    this.bridge.handleTtsEvent(requestId, 'start', 'started');
  }

  onComplete(requestId: string, _response: textToSpeech.CompleteResponse): void {
    // CoreSpeechKit reports both synthesis-complete and speech-complete; only
    // the latter marks the audible utterance as finished.
    if (_response.type === 1) {
      this.bridge.handleTtsEvent(requestId, 'end', 'completed');
    }
  }

  onStop(requestId: string, _response: textToSpeech.StopResponse): void {
    this.bridge.handleTtsEvent(requestId, 'end', 'stopped');
  }

  onError(requestId: string, errorCode: number, errorMessage: string): void {
    hilog.warn(DOMAIN, TAG, 'tts onError code=%{public}d msg=%{public}s', errorCode, errorMessage);
    this.bridge.handleTtsEvent(requestId, 'error', errorMessage);
  }
}

export class LegacyBridge {
  private static pendingOpenUrls: Array<string> = [];

  static setPendingOpenUrls(urls: Array<string>): void {
    LegacyBridge.pendingOpenUrls = urls;
  }

  static addPendingOpenUrl(url: string): void {
    if (url.length > 0 && LegacyBridge.pendingOpenUrls.indexOf(url) < 0) {
      LegacyBridge.pendingOpenUrls.push(url);
    }
  }

  /** 取走并清空待处理深链（Tauri 语义：get_current 读一次即消费）。 */
  static takePendingOpenUrls(): Array<string> {
    const urls = LegacyBridge.pendingOpenUrls;
    LegacyBridge.pendingOpenUrls = [];
    return urls;
  }

  private context: common.UIAbilityContext | null = null;
  private controller: webview.WebviewController | null = null;
  private mainWindow: window.Window | null = null;
  private isWindowMaximized: boolean = false;
  private injectScript: string = '';
  private nextHttpRid: number = 1;
  private httpClients: Map<number, http.HttpRequest> = new Map<number, http.HttpRequest>();
  private httpConfigs: Map<number, ESObject> = new Map<number, ESObject>();
  private httpBodies: Map<number, Uint8Array> = new Map<number, Uint8Array>();
  private httpOffsets: Map<number, number> = new Map<number, number>();
  /** 目录权限只在本次进程里申请一次（被拒则下次再问，见 ensureDirectoryPermissions）。 */
  private dirPermissionAsked: boolean = false;
  private rdbStores: Map<string, relationalStore.RdbStore> = new Map<string, relationalStore.RdbStore>();
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private wsConnections: Map<number, WsConn> = new Map();
  private wsNextConnId: number = 1;
  // Set by the UI page (Index.ets): opens the in-app web browser and resolves
  // with the clipped page HTML ('' when the user closes without clipping).
  private browserOpener: ((url: string, clipLabel: string, closeLabel: string) => Promise<string>) | null = null;
  private ttsInitPromise: Promise<boolean> | null = null;
  private ttsVoiceLang: string = 'zh-CN';
  private ttsVoicePerson: number = 0;
  private ttsVoiceId: string = 'harmony_zh-CN_0';
  private ttsVoices: Array<TtsVoiceInfo> = [];
  private ttsPlayoutSession: number = 0;
  private ttsPlayoutCurrentIndex: number = -1;
  private ttsPlayoutCurrentItem: TtsPlayoutItem | null = null;
  private ttsPlayoutCurrentPlayer: media.AVPlayer | null = null;
  private ttsPlayoutNextIndex: number = 0;
  private ttsPlayoutQueue: Array<TtsPlayoutItem> = [];
  private ttsPlayoutEndRequested: boolean = false;
  private ttsPlayoutRate: number = 1.0;
  private ttsAvSession: avSession.AVSession | null = null;
  private ttsRate: number = 1.0;
  private ttsPitch: number = 1.0;
  private ttsNextUtteranceId: number = 1;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  async initWindow(): Promise<void> {
    if (!this.context) return;
    try {
      this.mainWindow = await window.getLastWindow(this.context);
      this.isWindowMaximized =
        this.mainWindow.getWindowStatus() === window.WindowStatusType.MAXIMIZE;
      this.mainWindow.on('windowStatusChange', (status: window.WindowStatusType) => {
        this.isWindowMaximized = status === window.WindowStatusType.MAXIMIZE;
        hilog.info(DOMAIN, TAG, 'windowStatusChanged=%{public}d', status);
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getLastWindow failed: %{public}s', JSON.stringify(error));
    }
  }

  methodList(): Array<string> {
    return ['invoke', 'invokeAsync'];
  }

  loadInjectScript(): string {
    if (this.injectScript.length > 0) return this.injectScript;
    try {
      if (this.context) {
        const bytes = this.context.resourceManager.getRawFileContentSync('readest-bridge.js');
        this.injectScript = util.TextDecoder.create('utf-8').decodeToString(bytes);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'loadInjectScript failed: %{public}s', JSON.stringify(error));
    }
    return this.injectScript;
  }

  invoke(cmd: string, argsJson: string): string {
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

  invokeAsync(cmd: string, argsJson: string, callbackId: number): string {
    const args: ESObject = argsJson && argsJson.length > 0 ? JSON.parse(argsJson) : {};
    this.dispatchAsync(cmd, args).then((result: ESObject) => {
      if (this.controller) {
        this.controller.runJavaScript(
          `window.__READEST_BRIDGE__.resolve(${callbackId}, ${JSON.stringify(result)})`
        );
      }
    }).catch((error: ESObject) => {
      // String(BusinessError) 是 "[object Object]"，会把 code/message 全吞掉。
      const be = error as BusinessError;
      const detail = (be && be.code !== undefined)
        ? ('code=' + String(be.code) + ' msg=' + String(be.message))
        : String(error);
      this.diag('invokeAsync FAIL ' + cmd + ' err=' + detail);
      hilog.warn(DOMAIN, TAG, 'invokeAsync %{public}s failed: %{public}s', cmd, detail);
      if (this.controller) {
        this.controller.runJavaScript(
          `window.__READEST_BRIDGE__.reject(${callbackId}, ${JSON.stringify(String(detail))})`
        );
      }
    });
    return '';
  }

  interceptRequest(request: WebResourceRequest): WebResourceResponse | undefined {
    const rawUrl: string = request.getRequestUrl();
    if (rawUrl.indexOf('http://appassets.local/__rangefile__') === 0 ||
        rawUrl.indexOf('https://appassets.local/__rangefile__') === 0) {
      return this.serveLocalFile(rawUrl, request.getRequestMethod());
    }
    if (rawUrl.indexOf('http://appassets.local') === 0 ||
        rawUrl.indexOf('https://appassets.local') === 0) {
      return this.serveAppAsset(rawUrl);
    }
    return undefined;
  }

  private ok(data: ESObject): string {
    return JSON.stringify({ ok: true, data: data });
  }

  /** Absolute sandbox path of the most recent in-app-browser book download. */
  private lastDownloadPath: string = '';

  /** Sandbox path of the newest in-app-browser download ('' when none). */
  lastBrowserDownloadPath(): string {
    return this.lastDownloadPath;
  }

  /** Set by Index.ets so bridge-level status events can drive the browser UI. */
  private importStatusSink: ((state: string, filename: string) => void) | null = null;

  setImportStatusSink(sink: (state: string, filename: string) => void): void {
    this.importStatusSink = sink;
  }

  /**
   * TEMP diagnostic (book-open failure): hilog does not surface this app's
   * output reliably, so bridge failures are appended to a sandbox file.
   */
  private diagSink: ((message: string) => void) | null = null;

  /** 交给新核心的字节正确写入（本文件原实现用 writeSync(fd, string)，设备上写 0 字节）。 */
  setDiagSink(sink: (message: string) => void): void {
    this.diagSink = sink;
  }

  diag(message: string): void {
    if (this.diagSink !== null) {
      this.diagSink(message);
      return;
    }
    if (!this.context) return;
    try {
      const d = new Date();
      const mm = String(d.getMonth() + 1).padStart(2, '0');
      const dd = String(d.getDate()).padStart(2, '0');
      const ts = `${d.getHours()}:${d.getMinutes()}:${d.getSeconds()}.${d.getMilliseconds()}`;
      const f = fs.openSync(this.context.cacheDir + '/bridge-diag-' + mm + dd + '.log',
        fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE);
      try {
        fs.writeSync(f.fd, ts + ' ' + message + '\n');
      } finally {
        fs.closeSync(f.fd);
      }
    } catch (_e) {
    }
  }

  private fail(error: ESObject): string {
    return JSON.stringify({ ok: false, error: String(error) });
  }

  /**
   * LocalSendStatus wire shape (src/services/localsend/types.ts) with the
   * service fully stopped. Returned in place of `null` because the JS side
   * types the status as an OBJECT: several consumers read fields without
   * optional chaining, and `setStatus(null)` would crash them. A stopped
   * snapshot degrades the UI to "not running" instead.
   */
  private static emptyLocalSendStatus(): ESObject {
    return {
      running: false,
      alias: '',
      port: 0,
      fingerprint: '',
      deviceModel: 'HarmonyOS',
      localIps: [] as Array<string>,
      multicastError: null,
    };
  }

  private dispatch(cmd: string, args: ESObject): ESObject {
    switch (cmd) {
      case 'get_executable_dir':
        return this.context ? this.context.filesDir : '';
      case 'set_webview_info':
        return null;
      case 'get_webview_version':
        return { engine: 'ArkWeb', version: '' };
      case 'is_updater_disabled':
        return true;
      case 'allow_paths_in_scopes':
        return null;
      // 已迁移到 domains/ 的域：plugin:fs|* / plugin:path|* / plugin:window|*
      // 这三域的旧实现（原在此处，94 行）已于 2026-10-07 删除 ——
      // ReadestBridge.invoke/invokeAsync 会在进入本文件**之前**按前缀拦截，
      // 所以这些 case 从来不可达。新实现见 entry/src/main/ets/bridge/domains/。
      case 'plugin:deep-link|get_current':
        return LegacyBridge.pendingOpenUrls;
      case 'plugin:deep-link|is_registered':
        return false;
      case 'plugin:deep-link|register':
      case 'plugin:deep-link|unregister':
        return null;
      case 'plugin:opener|open_url':
        return this.openerOpenUrl(args);
      case 'plugin:opener|open_path':
        return null;
      case 'plugin:opener|reveal_item_in_dir':
        return null;
      case 'plugin:native-bridge|is_sync_keychain_available':
        return false;
      case 'localsend_stop':
        return null;
      // ── Not-yet-ported features: safe no-ops ─────────────────────────────
      // LocalSend (LAN device-to-device transfer) is not ported to HarmonyOS
      // yet. These fire at startup / on foreground / when the LocalSend UI is
      // opened, so return safe no-ops instead of throwing: the UI degrades to
      // "not running" and the log stops showing "unsupported bridge command".
      // Start/status return the stopped LocalSendStatus object shape; the
      // void lifecycle calls return null.
      case 'localsend_start':
      case 'localsend_get_status':
        return LegacyBridge.emptyLocalSendStatus();
      case 'localsend_set_discoverable':
      case 'localsend_announce':
        return null;
      // Peer discovery: empty list → the device picker shows "no devices"
      // and never reaches sendLocalSendFiles.
      case 'localsend_list_devices':
        return [] as Array<ESObject>;
      // false = "this window did not claim the request" — the TS contract
      // (src/services/localsend/service.ts) documents false as "another
      // window answered first, or the sender aborted", i.e. a decline the
      // caller already handles safely.
      case 'localsend_respond':
        return false;
      // Transfer control: void on the JS side; unreachable while the peer
      // list is empty, kept as a safety net.
      case 'localsend_cancel_receive':
      case 'localsend_send_files':
      case 'localsend_cancel_send':
        return null;
      case 'localsend_is_alive':
        return false;
      // Rust EPUB prefetch on the reader-open hot path: this SDK has no
      // native ZIP/inflate, so signal "native path unavailable".
      // tryNativePrefetchEpub checks `!rust || !rust.partialMd5 || ...` and
      // falls back to zip.js silently — returning null (instead of throwing)
      // keeps that fallback but drops the console.warn noise.
      // parse_epub_metadata is the same pattern on the import hot path
      // (tryNativeParseEpubMetadata checks partialMd5/opfPath/opfBytes).
      case 'parse_epub_full':
      case 'parse_epub_metadata':
        return null;
      // 其它格式的原生快路径，同理：返回 null 表示"没有原生解析器，走 JS 回退"。
      // 注意**不能抛错**：tryNativeParsePdf 用 `Promise.allSettled([parse_pdf_metadata,
      // render_pdf_cover])` 包住两者，**两个都 rejected 时会 throw**，而那个 throw
      // 会被 bookService 包成"无法打开书籍文件" → **PDF 导入整体失败**。
      // 只要有一条 fulfilled（哪怕值是 null），应用就会用 foliate-js 的 PDF 元数据
      // 兜底继续导入。
      case 'parse_pdf_metadata':
      case 'render_pdf_cover':
      case 'parse_mobi_metadata':
        return null;
      // 平台无关的能力（macOS 交通灯 / iOS Safari 授权），本移植不需要：
      // 静默 no-op，避免在日志里刷"unsupported"。
      case 'set_traffic_lights':
      case 'auth_with_safari':
        return null;
      // 自绘标题栏：系统标题不参与显示，no-op 即可（窗口标题按钮同样是自绘的）。
      case 'set_window_title':
        return null;
      // Tauri's env-var read. Both call sites tolerate '' safely:
      //   auth page: value === 'true' gates the custom OAuth server;
      //   useFileSelector: '' is falsy and .toLowerCase() is a no-op
      //   (gamescope detection on Steam Deck — irrelevant here).
      case 'get_environment_variable':
        return '';
      // Discord Rich Presence (guarded by isDesktopApp on the JS side).
      case 'clear_book_presence':
      case 'update_book_presence':
        return null;
      // Nightly updater: hasUpdater=false on HarmonyOS, so the UI never
      // offers an update; kept as a safety net. verify_update_signature
      // returning false = "signature invalid" fails the install flow closed
      // rather than installing an unverified package.
      case 'verify_update_signature':
        return false;
      case 'install_nightly_update':
        return null;
      // Cover thumbnail optimization: the cover lives INSIDE the book
      // archive (no standalone image on disk) and there is no native ZIP/inflate
      // to extract it, so a no-op success is correct. The JS path still renders
      // covers; this just silences the startup "[covers] ... failed" warning.
      case 'optimize_cover_thumbnails':
        return null;
      case 'plugin:clipboard-manager|write_text':
        return this.clipboardWriteText(args);
      case 'plugin:clipboard-manager|read_text':
        return this.clipboardReadText();
      case 'plugin:clipboard-manager|clear':
        return this.clipboardClear();
      case 'plugin:app|version':
        return '0.12.8';
      case 'plugin:app|name':
        return 'Readest';
      case 'plugin:app|identifier':
        return 'com.kehahn.readest';
      case 'plugin:app|tauri_version':
        return '2.11.5';
      case 'plugin:app|bundle_type':
        return 'app';
      case 'plugin:app|supports_multiple_windows':
        return false;
      case 'plugin:app|app_show':
        return this.windowShow();
      case 'plugin:app|app_hide':
        return this.windowHide();
      case 'plugin:app|set_app_theme':
        return null;
      case 'plugin:process|exit':
        return this.processExit();
      case 'plugin:process|restart':
        return this.processRestart();
      case 'plugin:native-tts|init':
        return this.ttsInit();
      case 'plugin:native-tts|get_all_voices':
        return this.ttsGetAllVoices();
      case 'plugin:native-tts|set_voice':
        return this.ttsSetVoice(args);
      case 'plugin:native-tts|set_rate':
        return this.ttsSetRate(args);
      case 'plugin:native-tts|set_pitch':
        return this.ttsSetPitch(args);
      case 'plugin:native-tts|speak':
        return this.ttsSpeak(args);
      case 'plugin:native-tts|pause':
        return this.ttsPause();
      case 'plugin:native-tts|resume':
        return this.ttsResume();
      case 'plugin:native-tts|stop':
        return this.ttsStop();
      case 'plugin:native-tts|checkPermissions':
      case 'plugin:native-tts|requestPermissions':
        return { postNotification: 'granted' };
      case 'plugin:native-tts|set_media_session_active':
      case 'plugin:native-tts|update_media_session_metadata':
      case 'plugin:native-tts|update_media_session_state':
      case 'plugin:native-tts|update_carplay_state':
        return null;
      // Cloud-sync transfer primitives (Google Drive / OneDrive / S3 /
      // WebDAV PUT upload & streaming download). These are Rust-only
      // commands with no HarmonyOS port, and a silent success would fake a
      // finished sync — so fail LOUDLY with a clear reason instead of the
      // generic "unsupported bridge command". The providers surface the
      // error, which is the honest outcome: cloud sync is unavailable here.
      case 'upload_file':
      case 'download_file':
        throw new Error(cmd + ' is not available on HarmonyOS: cloud sync transfers are not ported');
      default:
        if (cmd.indexOf('plugin:native-bridge|') === 0) {
          return false;
        }
        throw new Error('unsupported bridge command: ' + cmd);
    }
  }

  // ── WebSocket bridge (Tauri plugin-websocket; used by Edge TTS) ──────────
  // Frames are delivered to the frontend over the Tauri Channel (onMessage)
  // via window.__READEST_BRIDGE__.resolve(channelId, {index, message}).
  private async wsConnect(args: ESObject): Promise<ESObject> {
    const url = this.argString(args, 'url');
    const channelRaw: ESObject = args['onMessage'];
    const channelId = typeof channelRaw === 'number' ? channelRaw : -1;
    const headersRaw: ESObject = args['headers'];
    const header: Record<string, string> = {};
    if (headersRaw) {
      const keys: string[] = Object.keys(headersRaw);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        const v: ESObject = headersRaw[k];
        header[k] = String(v);
      }
    }
    const socket = webSocket.createWebSocket();
    const connId = this.wsNextConnId++;
    const conn = new WsConn(connId, socket, channelId);
    this.wsConnections.set(connId, conn);
    hilog.info(DOMAIN, TAG, 'ws connect id=%{public}d url=%{public}s channel=%{public}d', connId, url, channelId);
    socket.on('open', (_err: BusinessError, _res: Object): void => {
      hilog.info(DOMAIN, TAG, 'ws open id=%{public}d url=%{public}s', connId, url);
    });
    socket.on('message', (_err: BusinessError, data: string | ArrayBuffer): void => {
      if (typeof data === 'string') {
        this.wsDeliverText(conn, data);
      } else if (data) {
        const b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(data));
        this.wsDeliverBinary(conn, b64);
      }
    });
    socket.on('close', (_err: BusinessError, result: webSocket.CloseResult): void => {
      const code = result ? result.code : 1000;
      const reason = result && result.reason ? result.reason : '';
      this.wsDeliverClose(conn, code, reason);
      this.wsCleanup(connId);
    });
    socket.on('error', (err: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'ws error id=%{public}d url=%{public}s code=%{public}d', connId, url, err ? err.code : -1);
      this.wsDeliverClose(conn, 1006, 'error');
      this.wsCleanup(connId);
    });
    const options: webSocket.WebSocketRequestOptions = {};
    if (Object.keys(header).length > 0) {
      options.header = header;
    }
    try {
      await Promise.race([
        socket.connect(url, options),
        new Promise<boolean>((_resolve: (v: boolean) => void, reject: (e: Error) => void) => {
          setTimeout(() => reject(new Error('ws connect timeout after 12s')), 12000);
        }),
      ]);
    } catch (error) {
      this.wsCleanup(connId);
      throw new Error(String(error));
    }
    hilog.info(DOMAIN, TAG, 'ws connected id=%{public}d channel=%{public}d', connId, channelId);
    return { id: connId };
  }

  private wsDeliverText(conn: WsConn, text: string): void {
    this.wsDeliverJson(conn, '{"type":"Text","data":' + JSON.stringify(text) + '}');
  }

  private wsDeliverBinary(conn: WsConn, b64: string): void {
    this.wsDeliverJson(conn, '{"type":"Binary","data":{"__readestBytes":' + JSON.stringify(b64) + '}}');
  }

  private wsDeliverClose(conn: WsConn, code: number, reason: string): void {
    this.wsDeliverJson(conn, '{"type":"Close","data":{"code":' + code + ',"reason":' + JSON.stringify(reason) + '}}');
  }

  private wsDeliverJson(conn: WsConn, messageJson: string): void {
    if (!this.controller || conn.channelId < 0) return;
    const payload = '{"index":' + conn.index + ',"message":' + messageJson + '}';
    conn.index++;
    try {
      this.controller.runJavaScript(
        `window.__READEST_BRIDGE__ && window.__READEST_BRIDGE__.resolve(${conn.channelId}, ${payload})`
      );
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'ws deliver failed: %{public}s', String(error));
    }
  }

  private wsSend(args: ESObject): ESObject {
    const idRaw: ESObject = args['id'];
    const connId = typeof idRaw === 'number' ? idRaw : -1;
    const conn = this.wsConnections.get(connId);
    if (!conn) return null;
    const message: ESObject = args['message'] ? (args['message'] as ESObject) : {};
    const type = this.argString(message, 'type');
    if (type === 'Close') {
      this.wsCleanup(connId);
      return null;
    }
    if (type === 'Binary') {
      const data: ESObject = message['data'];
      if (Array.isArray(data)) {
        const arr: ESObject[] = data as ESObject[];
        const u8 = new Uint8Array(arr.length);
        for (let i = 0; i < arr.length; i++) u8[i] = Number(arr[i]);
        conn.socket.send(u8.buffer as ArrayBuffer).catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'ws send binary failed: %{public}s', String(e));
        });
      }
      return null;
    }
    const text = this.argString(message, 'data');
    conn.socket.send(text).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'ws send failed: %{public}s', String(e));
    });
    return null;
  }

  private wsCleanup(connId: number): void {
    const conn = this.wsConnections.get(connId);
    if (conn) {
      try { conn.socket.close(); } catch (error) { /* already closed */ }
    }
    this.wsConnections.delete(connId);
  }

  // clip_url: fetch a URL server-side and return the page HTML so the web
  // clipper can convert it (readability + ePub) without CORS. A simple HTTP GET
  // (browser UA) instead of the desktop hidden-webview SSR; good for static/SSR
  // article pages.
  private async fetchHtml(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
        },
        connectTimeout: 20000,
        readTimeout: 25000,
      };
      const resp = await req.request(url, opts);
      const result = resp.result;
      let html = '';
      if (typeof result === 'string') {
        html = result;
      } else if (result instanceof ArrayBuffer) {
        html = util.TextDecoder.create('utf-8').decode(new Uint8Array(result));
      }
      if (html.length === 0) {
        throw new Error('empty body, status=' + resp.responseCode);
      }
      return html;
    } finally {
      req.destroy();
    }
  }

  private async clipUrl(args: ESObject): Promise<string> {
    const url = this.argString(args, 'url');
    if (url.length === 0) throw new Error('clip_url: empty url');
    hilog.info(DOMAIN, TAG, 'clip_url fetching url=%{public}s', url);
    try {
      const html = await this.fetchHtml(url);
      hilog.info(DOMAIN, TAG, 'clip_url ok len=%{public}d url=%{public}s', html.length, url);
      return html;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clip_url fetch error url=%{public}s err=%{public}s', url, String(error));
      throw new Error('clip_url fetch failed: ' + String(error));
    }
  }

  // open_web_browser: the desktop impl opens an in-app browser (sign in, then
  // Clip Page). Here we fetch the page HTML directly and hand it back as the
  // clipped result, which covers public/static article & novel pages without an
  // interactive browser window. (Interactive login browser is a future item.)
  private async openWebBrowser(args: ESObject): Promise<ESObject> {
    const url = this.argString(args, 'url');
    if (url.length === 0) {
      return {};
    }
    const options: ESObject = args['options'] ? (args['options'] as ESObject) : {};
    const labels: ESObject = options['labels'] ? (options['labels'] as ESObject) : {};
    const clipLabel = this.argString(labels, 'clipPage');
    const closeLabel = this.argString(labels, 'close');
    let html = '';
    hilog.info(DOMAIN, TAG, 'open_web_browser opener=%{public}s url=%{public}s', String(this.browserOpener !== null), url);
    if (this.browserOpener) {
      try {
        html = await this.browserOpener(url,
          clipLabel.length > 0 ? clipLabel : 'Clip Page',
          closeLabel.length > 0 ? closeLabel : 'Close');
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'open_web_browser browser failed url=%{public}s err=%{public}s', url, String(error));
        html = '';
      }
    } else {
      // No UI host registered: fall back to a direct fetch of the page.
      try {
        html = await this.fetchHtml(url);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'open_web_browser fetch failed url=%{public}s err=%{public}s', url, String(error));
        html = '';
      }
    }
    if (html.length === 0) {
      return {};
    }
    hilog.info(DOMAIN, TAG, 'open_web_browser clipped len=%{public}d url=%{public}s', html.length, url);
    const page: WebBrowserPageObj = { url: url, html: html };
    const result: WebBrowserResultObj = { page: page };
    return result;
  }

  setBrowserOpener(fn: (url: string, clipLabel: string, closeLabel: string) => Promise<string>): void {
    this.browserOpener = fn;
  }

  // Called from the in-app web browser's page via javaScriptProxy (encoding-safe
  // channel) with the clipped page HTML: write it to a temp file so ArkTS can
  // read it back as UTF-8 (runJavaScript's string return mangles CJK text).
  saveBrowserClipHtml(html: string): void {
    if (!this.context || html.length === 0) return;
    const path = this.context.cacheDir + '/browser-clip.html';
    try {
      const u8 = util.TextEncoder.create('utf-8').encodeInto(html);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, u8.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(file.fd);
      }
      let codes = '';
      const ncode = Math.min(html.length, 16);
      for (let i = 0; i < ncode; i++) {
        codes += html.charCodeAt(i).toString(16) + ',';
      }
      hilog.info(DOMAIN, TAG, 'browser clip saved len=%{public}d head=[%{public}s] codes=[%{public}s]', html.length, html.substring(0, 30), codes);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'browser clip save failed: %{public}s', String(error));
    }
  }

  readBrowserClip(): string {
    if (!this.context) return '';
    const path = this.context.cacheDir + '/browser-clip.html';
    try {
      return fs.readTextSync(path);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'browser clip read failed: %{public}s', String(error));
      return '';
    }
  }

  // Native GET returning { url, status, contentType, body(base64) } — used by
  // the web clipper's chapter/image/favicon fetches (services/webBrowser/browserFetch.ts).
  private async fetchWebBrowserResource(args: ESObject): Promise<ESObject> {
    const url = this.argString(args, 'url');
    if (url.length === 0) throw new Error('fetch_web_browser_resource: empty url');
    const headersRaw: ESObject = args['headers'];
    const header: Record<string, string> = {};
    if (headersRaw) {
      const keys: string[] = Object.keys(headersRaw);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        const v: ESObject = headersRaw[k];
        header[k] = String(v);
      }
    }
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 20000,
        readTimeout: 30000,
      };
      const resp = await req.request(url, opts);
      const result = resp.result;
      let b64 = '';
      if (typeof result === 'string') {
        b64 = new util.Base64Helper().encodeToStringSync(util.TextEncoder.create('utf-8').encodeInto(result));
      } else if (result instanceof ArrayBuffer) {
        b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(result));
      }
      let contentType = 'application/octet-stream';
      const headersObj: ESObject = resp.header as ESObject;
      if (headersObj) {
        const ct: ESObject = headersObj['content-type'];
        const ct2: ESObject = headersObj['Content-Type'];
        if (ct !== undefined && ct !== null) {
          contentType = String(ct);
        } else if (ct2 !== undefined && ct2 !== null) {
          contentType = String(ct2);
        }
      }
      hilog.info(DOMAIN, TAG, 'fetch_web_browser_resource ok status=%{public}d len=%{public}d url=%{public}s', resp.responseCode, b64.length, url);
      const resource: BrowserResourceObj = { url: url, status: resp.responseCode, contentType: contentType, body: b64 };
      return resource;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'fetch_web_browser_resource failed url=%{public}s err=%{public}s', url, String(error));
      throw new Error('fetch_web_browser_resource failed: ' + String(error));
    } finally {
      req.destroy();
    }
  }

  private async dispatchAsync(cmd: string, args: ESObject): Promise<ESObject> {
    switch (cmd) {
      case 'plugin:native-tts|init':
        return await this.ttsInitAsync();
      case 'plugin:native-tts|get_all_voices':
        return await this.ttsGetAllVoicesAsync();
      case 'plugin:native-tts|playout_control':
        return this.ttsPlayoutControl(args);
      case 'plugin:native-tts|playout_enqueue':
        return await this.ttsPlayoutEnqueue(args);
      case 'plugin:native-tts|playout_position':
        return await this.ttsPlayoutPosition();
      case 'plugin:native-tts|set_media_session_active':
        return await this.ttsMediaSetActive(args);
      case 'plugin:native-tts|update_media_session_metadata':
        return await this.ttsMediaUpdateMetadata(args);
      case 'plugin:native-tts|update_media_session_state':
        return await this.ttsMediaUpdateState(args);
      case 'plugin:native-bridge|copy_uri_to_path':
        return await this.nativeCopyUriToPath(args);
      case 'plugin:dialog|open':
        return await this.dialogOpen(args);
      case 'plugin:dialog|save':
        return await this.dialogSave(args);
      case 'plugin:http|fetch':
        return this.httpCreate(args);
      case 'plugin:http|fetch_send':
        return await this.httpSend(args);
      case 'plugin:http|fetch_read_body':
        return this.httpReadBody(args);
      case 'plugin:http|fetch_cancel':
        return this.httpCancel(args);
      case 'plugin:http|fetch_cancel_body':
        return this.httpCancelBody(args);
      case 'plugin:turso|load':
        return await this.tursoLoad(args);
      case 'plugin:turso|execute':
        return await this.tursoExecute(args);
      case 'plugin:turso|select':
        return await this.tursoSelect(args);
      case 'plugin:turso|batch':
        return await this.tursoBatch(args);
      case 'plugin:turso|close':
        return await this.tursoClose(args);
      case 'plugin:turso|get_config':
        return { encrypted: false };
      case 'plugin:turso|ping':
        return args ? (args.payload ? args.payload : null) : null;
      case 'plugin:turso|sync':
        return null;
      case 'plugin:websocket|connect':
        return await this.wsConnect(args);
      case 'plugin:websocket|send':
        return this.wsSend(args);
      case 'clip_url':
        return await this.clipUrl(args);
      case 'open_web_browser':
        return await this.openWebBrowser(args);
      case 'set_web_browser_status':
        this.relayWebBrowserStatus(args);
        return null;
      case 'extract_web_browser_archive':
        return await this.webBrowserArchiveExtract(args);
      case 'fetch_web_browser_resource':
        return await this.fetchWebBrowserResource(args);
      default:
        throw new Error('unsupported async bridge command: ' + cmd);
    }
  }

  // ── path ─────────────────────────────────────────────────────────────

  /**
   * Root that holds `library.json` + `Books/<hash>/`. Defaults to the app's own
   * data dir; a user-chosen folder (survives uninstall) overrides it. Upstream's
   * equivalent is `settings.localBooksDir`, but the webapp only *caches* that
   * value: it recomputes the real root every start through `getPrefix('Books')`,
   * i.e. this bridge's `resolve_directory`. Redirection therefore lives here and
   * needs no frontend rebuild.
   */
  private libraryRootOverride: string = '';

  setLibraryRootOverride(root: string): void {
    this.libraryRootOverride = root;
  }

  /** Physical root of the library tree (`library.json` + `Books/`). */
  libraryRoot(): string {
    if (this.libraryRootOverride.length > 0) return this.libraryRootOverride;
    return this.defaultLibraryRoot();
  }

  private defaultLibraryRoot(): string {
    if (!this.context) return '';
    return `${this.context.filesDir}/data/Readest`;
  }

  /**
   * Map a logical library path (the default location, which is what the webapp
   * knows and stores in `library.json`) onto its physical location.
   */
  private toPhysical(logicalPath: string): string {
    const root = this.libraryRoot();
    const def = this.defaultLibraryRoot();
    if (root.length === 0 || def.length === 0 || root === def) return logicalPath;
    if (logicalPath === def) return root;
    if (logicalPath.indexOf(def + '/') === 0) return root + logicalPath.slice(def.length);
    return logicalPath;
  }

  // ── fs ───────────────────────────────────────────────────────────────

  /** Resolve `{ path, options:{ baseDir } }` into an absolute physical path. */


  /**
   * Write commands carry a binary body: `readest-bridge.js` moves the real
   * `{ path, options }` into `options.headers`, URL-encoding the path and
   * JSON-encoding the options, and rewrites the pair as `__readestHeaders`.
   */














  /**
   * Decode a write payload. `readest-bridge.js` `encode()` turns any
   * Uint8Array/ArrayBuffer into `{ __readestUint8: base64 }`, and the
   * `read_text_file`-style commands that carry text also arrive that way, so
   * the payload reaches the command as `__readestArgs.__readestUint8`.
   * Legacy callers may still hand over a plain base64 string.
   */


  private bytesFromPayload(value: ESObject): Uint8Array {
    if (typeof value === 'string') {
      const text = String(value);
      if (text.length === 0) return new Uint8Array(0);
      try {
        return new util.Base64Helper().decodeSync(text);
      } catch (_error) {
        // Not base64: treat it as raw UTF-8 text.
        return this.encodeUtf8(text);
      }
    }
    if (value !== undefined && value !== null && typeof value === 'object') {
      const wrapped: ESObject = value['__readestUint8'];
      if (wrapped !== undefined && wrapped !== null) return this.bytesFromPayload(wrapped);
      const data: ESObject = value['data'];
      if (data !== undefined && data !== null) return this.bytesFromPayload(data);
    }
    return new Uint8Array(0);
  }

  /**
   * UTF-8 encode a string. The destination is allocated by code point (3 bytes
   * each) because that is the API's shape, so the *written* length returned by
   * encodeIntoUint8Array must be carried alongside: writing the whole buffer
   * appends zero padding to the file (observed as a 13-char string read back as
   * 39 chars).
   */
  private encodeUtf8Sized(text: string): SizedBytes {
    const dest = new Uint8Array(text.length * 3);
    const result: SizedBytes = { bytes: dest, size: 0 };
    if (text.length === 0) return result;
    try {
      const info = util.TextEncoder.create('utf-8').encodeIntoUint8Array(text, dest);
      result.size = info.written;
    } catch (_error) {
      result.size = 0;
    }
    return result;
  }

  private encodeUtf8(text: string): Uint8Array {
    const sized = this.encodeUtf8Sized(text);
    return new Uint8Array(sized.bytes.buffer.slice(0, sized.size) as ArrayBuffer);
  }

  /** Write exactly the given bytes to `path`, truncating any previous file. */


  private ensureParent(path: string): void {
    const slash = path.lastIndexOf('/');
    if (slash <= 0) return;
    const dir = path.slice(0, slash);
    try {
      if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) fs.mkdirSync(dir, true);
    } catch (_error) {
    }
  }





  /** `rmdirSync` only removes empty directories; walk children first. */
  private removeDirRecursive(dir: string): void {
    const names = fs.listFileSync(dir, { recursion: false });
    for (let i = 0; i < names.length; i++) {
      const full = dir + '/' + names[i];
      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (_error) {
        continue;
      }
      if (isDir) {
        this.removeDirRecursive(full);
      } else {
        fs.unlinkSync(full);
      }
    }
    fs.rmdirSync(dir);
  }



























  // ── window ───────────────────────────────────────────────────────────





  /**
   * Whether the window currently covers (nearly) the whole screen.
   *
   * Do NOT use `getWindowStatus()` here: on API 26 / 2in1 it does not follow
   * the enum (floating returns 4, maximized never reports MAXIMIZE(2)), so an
   * enum comparison is always false and "double-click to maximize" can never
   * restore. Geometry is the reliable signal (P-067 in the porting notes).
   */


  /** Keep the system-drawn window buttons visible after a state change. */
  private keepTitleButtonsVisible(): void {
    if (!this.mainWindow) return;
    try {
      this.mainWindow.setWindowTitleButtonVisible(true, true, true);
    } catch (_error) {
    }
  }









  private windowShow(): ESObject {
    if (this.mainWindow) {
      try {
        this.mainWindow.showWindow();
        this.keepTitleButtonsVisible();
      } catch (_error) {
      }
    }
    return null;
  }

  private windowHide(): ESObject {
    if (this.mainWindow) {
      try {
        this.mainWindow.minimize();
      } catch (_error) {
      }
    }
    return null;
  }

















  /**
   * Title-bar drag. Skipped while maximized: the system's semantics for
   * dragging a maximized window is "restore first, then drag", and the page
   * fires this on every mousedown — so an unconditional `startMoving()` made a
   * single click on the title bar drop the window out of its maximized state.
   * The page cannot apply the usual ~5px movement threshold itself.
   */


  // ── file picker / uri helpers ────────────────────────────────────────

  /**
   * 按需申请"读取用户目录"的运行时权限（Documents / Download / Desktop）。
   *
   * 为什么必须有这一步：`ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY` 是
   * **user_grant** 权限 —— 全新安装后 `bm dump` 里状态是 **-1（DENIED）**，
   * 必须在运行时弹窗授权。而上游请求权限的代码**全被 `isAndroidApp` 守着**
   * （`nativeAppService.openFile` / `library/page.tsx` / `appService.saveLibraryBooks`），
   * 我们 ArkTS 侧也从没请求过 → 鸿蒙上永远不会触发。
   *
   * 后果（2026-09-28 实测，全新安装）：
   *   · 单文件导入：`copy_uri_to_path` 按真实路径读用户选的文件 → 权限不足 →
   *     返回 `{success:false}` → 前端报"无法打开书籍文件"；
   *   · 从文件夹导入：`plugin:fs|read_dir` 列目录失败 → "无法读取此文件夹"。
   * 我们这台机器此前能导入，是因为**历史上授权过**；一旦卸载重装（即使 -k 保留数据，
   * 权限也会被重置）就复现。
   *
   * 时机放在 `dialogOpen` 里（用户选完文件之后）：只在真的要选书时弹窗，
   * 不影响启动体验。被拒则清掉标记，下次再问。
   */
  private async ensureDirectoryPermissions(): Promise<void> {
    if (this.dirPermissionAsked || !this.context) return;
    this.dirPermissionAsked = true;
    try {
      const perms: Array<Permissions> = [
        'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
        'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
      ];
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(this.context, perms);
      let granted = 0;
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] === 0) granted++;
      }
      this.diag('dir permission requested: granted=' + String(granted) + '/' +
        String(result.authResults.length) + ' authResults=' + JSON.stringify(result.authResults));
      if (granted === 0) this.dirPermissionAsked = false; // 被拒 → 下次再问
    } catch (error) {
      const be = error as BusinessError;
      this.diag('dir permission request FAILED code=' + String(be.code) + ' msg=' + String(be.message));
      this.dirPermissionAsked = false;
    }
  }

  private async persistUris(uris: Array<string>): Promise<void> {
    if (uris.length === 0) return;
    try {
      const policies: Array<fileShare.PolicyInfo> = [];
      for (let i = 0; i < uris.length; i++) {
        policies.push({
          uri: uris[i],
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
        });
      }
      await fileShare.persistPermission(policies);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'persist uri permissions failed: %{public}s', String(error));
    }
  }

  /**
   * `plugin:native-bridge|copy_uri_to_path`: the picker hands back a
   * `file://docs/...` uri; the reader and the import path want a real sandbox
   * file, so copy the bytes into the app cache and hand the new path back.
   */
  private async nativeCopyUriToPath(args: ESObject): Promise<ESObject> {
    // JS 契约（src/utils/bridge.ts::copyURIToPath + nativeAppService.openFile）：
    //   invoke('plugin:native-bridge|copy_uri_to_path', { payload: { uri, dst } })
    //   → { success: boolean, error?: string }
    //
    // 旧实现有三个不符：取的是 `args.uri`/`args.path`（真实字段在 `payload` 里，
    // 且目标字段叫 `dst`），返回裸路径字符串，失败时返回 null。调用方是
    //   const res = await copyURIToPath({uri, dst});
    //   if (!res.success) …
    // 于是 `null.success` 直接抛 TypeError —— 真机表现（2026-09-28）：
    //   导入书籍失败：Failed to open the book file:
    //   Cannot read properties of null (reading 'success')
    //
    // 影响面是**全部本地文件导入**：nativeAppService.openFile 的条件是
    // `isFileURI(path) && isHarmonyOSApp()`，而我们的 shim 设了
    // `window.__READEST_HARMONY__ = true`，所以每个本地文件都会走到这里。
    const payload: ESObject = this.argPayload(args);
    const uri = this.argString(payload, 'uri');
    const dst = this.argString(payload, 'dst');
    if (uri.length === 0 || dst.length === 0) {
      this.diag('copy_uri_to_path: missing uri/dst args=' + String(JSON.stringify(args)).slice(0, 160));
      return { success: false, error: 'copy_uri_to_path: missing uri/dst' };
    }
    // 兜底：URI 也可能来自持久化的"上次导入目录"等路径，未必经过 dialogOpen。
    await this.ensureDirectoryPermissions();
    const target = this.toPhysical(dst);
    try {
      this.ensureParent(target);
      // 逐个候选打开源文件：
      //   ① 真实路径 —— 需要 READ_WRITE_*_DIRECTORY（Documents/Download 已申请）
      //   ② 原始 URI —— 选择器给的 URI 自带一次性授权，所以"权限声明不了"的位置
      //      （如桌面：availableLevel=system_basic）也还有机会读到
      // 记下最后用的是哪个候选，便于以后按证据判断。
      const candidates: Array<string> = [this.uriToPhysical(uri), uri];
      let src: fs.File | undefined = undefined;
      let openedAs = '';
      let lastError = '';
      for (let i = 0; i < candidates.length; i++) {
        const candidate = candidates[i];
        if (candidate.length === 0) continue;
        try {
          src = fs.openSync(candidate, fs.OpenMode.READ_ONLY);
          openedAs = candidate;
          break;
        } catch (openError) {
          const be = openError as BusinessError;
          lastError = 'code=' + String(be.code) + ' msg=' + String(be.message);
        }
      }
      if (src === undefined) {
        throw new Error('cannot open source (last ' + lastError + ')');
      }
      const out = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
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
      this.diag('copy_uri_to_path ok uri=' + uri + ' via=' + openedAs +
        ' dst=' + target + ' bytes=' + String(copied));
      return { success: true };
    } catch (error) {
      const be = error as BusinessError;
      const detail = 'code=' + String(be.code) + ' msg=' + String(be.message);
      this.diag('copy_uri_to_path FAILED uri=' + uri + ' dst=' + dst + ' ' + detail);
      return { success: false, error: detail };
    }
  }

  /**
   * 选择器给的 URI → 能直接喂给 fileIo 的真实路径。
   *
   * 真机取到的是 `file://docs/<用户目录>/...`：`docs` 是 authority，
   * 真实路径是它后面的部分（`/<用户目录>/...`）。其余 scheme 原样透传，
   * 让 fileIo 自己决定能否处理（不能处理就返回 {success:false} 响亮失败）。
   */
  private uriToPhysical(uri: string): string {
    // 单一来源：BridgeProtocol.uriToPath（覆盖 file: 的四种写法 + 百分号解码）。
    // 这里曾经是**另一份实现**且漏了解码，导致"目录对话框回可读路径"永远判定失败。
    return uriToPath(uri);
  }

  // ── base dirs ────────────────────────────────────────────────────────



  /**
   * Turn a path plus its base into an absolute path. An already-absolute path
   * (or one carrying a URI scheme) is passed through `toPhysical` so a
   * redirected library keeps working for previously stored absolute paths.
   */


  // ── path ─────────────────────────────────────────────────────────────

  private argString(args: ESObject, key: string): string {
    const value: ESObject = args ? args[key] : undefined;
    return value === undefined || value === null ? '' : String(value);
  }

  private argNumber(args: ESObject, key: string, fallback: number): number {
    const value: ESObject = args ? args[key] : undefined;
    if (value === undefined || value === null) return fallback;
    const n = Number(value);
    return isNaN(n) ? fallback : n;
  }

  /**
   * `plugin:path|resolve_directory` — the base directory request. Note this is
   * the hook that makes a user-chosen library folder work: the webapp asks for
   * `AppData` + `Readest` on every start and caches nothing but the answer.
   */












  /** Collapse `//`, `.` and `..` segments while keeping the path absolute. */




  /** Resolve a list of paths right-to-left, like `path.resolve`. */


  private async dialogOpen(args: ESObject): Promise<ESObject> {
    if (!this.context) throw new Error('context not ready');
    const options: ESObject = args ? args.options : undefined;
    const directory: boolean = options ? options.directory === true : false;
    const multiple: boolean = options ? options.multiple === true : false;
    const pickerOptions: picker.DocumentSelectOptions = {
      maxSelectNumber: multiple ? 100 : 1,
    };
    if (directory) {
      pickerOptions.selectMode = picker.DocumentSelectMode.FOLDER;
      pickerOptions.maxSelectNumber = 1;
    }
    const viewPicker = new picker.DocumentViewPicker(this.context);
    // 选择器这一步必须留痕：应用侧的 selectFiles 会把异常吞成
    // `{files: [], error}` 然后**静默返回**（一行日志都没有），
    // 于是"点了导入没反应"在日志里完全查不到。这里记录：模式 / 选了几个 / 第一个 URI。
    let uris: Array<string> = [];
    try {
      uris = await viewPicker.select(pickerOptions);
    } catch (error) {
      const be = error as BusinessError;
      this.diag('dialogOpen: picker THREW mode=' + (directory ? 'folder' : 'file') +
        ' code=' + String(be.code) + ' msg=' + String(be.message));
      // ArkTS 不允许 throw 任意类型的值（arkts-limited-throw），必须包成 Error。
      throw new Error('picker failed: code=' + String(be.code) + ' msg=' + String(be.message));
    }
    this.diag('dialogOpen: mode=' + (directory ? 'folder' : 'file') +
      ' multiple=' + String(multiple) + ' picked=' + String(uris ? uris.length : -1) +
      (uris && uris.length > 0 ? ' first=' + uris[0] : ' (取消或空)'));
    if (!uris || uris.length === 0) return null;
    // 选完之后按需申请目录权限：文件导入与"从文件夹导入"都走这里，
    // 少了它全新安装会分别报"无法打开书籍文件"/"无法读取此文件夹"。
    await this.ensureDirectoryPermissions();
    // 持久授权必须用**系统给的原始 URI**（带百分号编码），别用下面可能被改写的形态。
    await this.persistUris(uris);
    if (directory) {
      // 目录：优先回**可读的真实路径**。上游桌面端本来就是回真实路径，
      // 界面显示干净；而鸿蒙选择器给的是 `file:///docs/…/%E6%B5%8B%E8%AF%95/…`
      // 这种标识，直接显示出来既长又像乱码（用户明确反馈过）。
      // 但"能不能按路径访问"因位置/权限而异 → 这里**当场实际列一次目录**再决定，
      // 列得动就回路径，列不动就退回 URI（功能优先，绝不猜）。
      const out: Array<string> = [];
      for (let i = 0; i < uris.length; i++) {
        out.push(this.preferReadableDirectory(uris[i]));
      }
      return multiple ? out : out[0];
    }
    return multiple ? uris : uris[0];
  }

  /**
   * 目录选择器的返回值：能按真实路径访问就回真实路径（界面可读），否则回 URI。
   *
   * 判据是**实际列一次目录**而不是假设 —— 同一个 URI 在不同位置/权限下结果不同
   * （Documents/下载 有 user_grant 目录权限，桌面没有）。这样既不牺牲能力，
   * 也不把又长又像乱码的 URI 显示给用户。
   */
  private preferReadableDirectory(uri: string): string {
    const physical = this.uriToPhysical(uri);
    if (physical === uri) return uri; // 不是 file URI，原样返回
    try {
      fs.listFileSync(physical);
      this.diag('dialog dir → real path: ' + physical);
      return physical;
    } catch (error) {
      this.diag('dialog dir → keep URI (path not listable: ' + String(error) + '): ' + uri);
      return uri;
    }
  }

  /**
   * 保存对话框（Tauri `plugin:dialog|save`）。
   *
   * 2026-10-10 修两处：
   *  1. **必须把应用传来的文件名交给选择器**。原先 saveOptions 是空对象，文件名被丢，
   *     落盘名字不可控、部分版本直接失败（用户报"备份书库→保存失败"）。
   *     Tauri 侧的入参是 `options.defaultPath`（例如 `readest-backup-2026-10-10.zip`）。
   *  2. **全程留痕**：入参、选择器返回、真实路径、异常。原先这个函数一行日志都没有，
   *     导致"保存失败"在诊断里查不到任何线索。
   */
  private async dialogSave(args: ESObject): Promise<ESObject> {
    if (!this.context) throw new Error('context not ready');
    const options: ESObject = args ? args.options : undefined;
    const defaultPath: string = options ? this.argString(options, 'defaultPath') : '';
    let fileName: string = 'readest-backup.zip';
    if (defaultPath.length > 0) {
      const parts: Array<string> = defaultPath.split('/');
      const leaf: string = parts[parts.length - 1];
      if (leaf.length > 0) fileName = leaf;
    }
    const saveOptions: picker.DocumentSaveOptions = { newFileNames: [fileName] };
    this.diag('dialogSave: defaultPath=' + defaultPath + ' newFileNames=' + fileName);
    try {
      const viewPicker = new picker.DocumentViewPicker(this.context);
      const uris: Array<string> = await viewPicker.save(saveOptions);
      this.diag('dialogSave: uris=' + JSON.stringify(uris).slice(0, 240));
      if (!uris || uris.length === 0) return null;
      await this.persistUris(uris);
      try {
        this.diag('dialogSave: real path=' + uriToPath(uris[0]));
      } catch (e2) {
        this.diag('dialogSave: uriToPath failed ' + String(e2));
      }
      return uris[0];
    } catch (error) {
      this.diag('dialogSave FAILED: ' + String(error));
      throw error as Error;
    }
  }


  private httpMethod(method: string): http.RequestMethod {
    const m = method.toUpperCase();
    if (m === 'POST') return http.RequestMethod.POST;
    if (m === 'PUT') return http.RequestMethod.PUT;
    if (m === 'DELETE') return http.RequestMethod.DELETE;
    if (m === 'PATCH') return http.RequestMethod.PUT;
    if (m === 'HEAD') return http.RequestMethod.HEAD;
    if (m === 'OPTIONS') return http.RequestMethod.OPTIONS;
    return http.RequestMethod.GET;
  }

  private numbersToBuffer(data: ESObject): ArrayBuffer {
    if (!Array.isArray(data)) return new ArrayBuffer(0);
    const values = data as Array<number>;
    const bytes = new Uint8Array(values.length);
    for (let i = 0; i < values.length; i++) {
      bytes[i] = Number(values[i]) & 0xff;
    }
    return bytes.buffer as ArrayBuffer;
  }

  private buildHttpOptions(clientConfig: ESObject): http.HttpRequestOptions {
    const header: Record<string, string> = {};
    const rawHeaders: ESObject = clientConfig ? clientConfig.headers : undefined;
    if (Array.isArray(rawHeaders)) {
      const pairs = rawHeaders as Array<Array<string>>;
      for (let i = 0; i < pairs.length; i++) {
        const pair = pairs[i];
        if (pair && pair.length >= 2) {
          header[String(pair[0])] = String(pair[1]);
        }
      }
    }
    const options: http.HttpRequestOptions = {
      method: this.httpMethod(clientConfig ? String(clientConfig.method || 'GET') : 'GET'),
      header: header,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      connectTimeout: 30000,
      readTimeout: 120000,
    };
    const body: ESObject = clientConfig ? clientConfig.data : undefined;
    if (Array.isArray(body)) {
      options.extraData = this.numbersToBuffer(body);
    }
    return options;
  }

  private responseData(resp: http.HttpResponse): Uint8Array {
    if (resp.result instanceof ArrayBuffer) {
      return new Uint8Array(resp.result as ArrayBuffer);
    }
    if (typeof resp.result === 'string') {
      return util.TextEncoder.create('utf-8').encodeInto(String(resp.result));
    }
    return new Uint8Array(0);
  }

  private responseHeaders(header: Object): Array<Array<string>> {
    const result: Array<Array<string>> = [];
    if (!header) return result;
    const obj: ESObject = header as ESObject;
    const keys = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value: ESObject = obj[key];
      if (Array.isArray(value)) {
        const arr = value as Array<string>;
        for (let j = 0; j < arr.length; j++) {
          result.push([key, String(arr[j])]);
        }
      } else {
        result.push([key, String(value)]);
      }
    }
    return result;
  }

  private httpCreate(args: ESObject): number {
    const client = http.createHttp();
    const rid = this.nextHttpRid++;
    this.httpClients.set(rid, client);
    this.httpConfigs.set(rid, args);
    return rid;
  }

  private async httpSend(args: ESObject): Promise<ESObject> {
    const rid = this.argNumber(args, 'rid', -1);
    const client: http.HttpRequest | undefined = this.httpClients.get(rid);
    const configWrapper: ESObject | undefined = this.httpConfigs.get(rid);
    if (!client || !configWrapper) throw new Error('invalid http rid: ' + rid);
    const clientConfig: ESObject = configWrapper.clientConfig ? configWrapper.clientConfig : configWrapper;
    const url = String(clientConfig.url || '');
    let response: http.HttpResponse;
    try {
      response = await client.request(url, this.buildHttpOptions(clientConfig));
    } catch (error) {
      // `String(BusinessError)` 是 "[object Object]"，会把错误码整个吞掉
      // （2026-09-28 就是因此只看到 `invokeAsync FAIL … err=[object Object]`）。
      // 失败路径同样要回收句柄，否则失败一次漏一个。
      const be = error as BusinessError;
      const detail = 'code=' + String(be.code) + ' msg=' + String(be.message);
      this.diag('http request FAILED url=' + url + ' ' + detail);
      this.destroyHttpClient(rid);
      throw new Error('http request failed: ' + detail);
    }
    this.httpBodies.set(rid, this.responseData(response));
    this.httpOffsets.set(rid, 0);
    return {
      status: Number(response.responseCode),
      statusText: '',
      // 说明：`@ohos.net.http` **会自动跟随重定向且不暴露最终地址**（HttpResponse 无该字段，
      // 且 `maxRedirects: 0` 被平台忽略 —— 2026-10-03 医生页用例实测 status=200、
      // final 仍是原始地址）。因此这里只能回原始请求地址：plugin-http 的客户端会把它当作
      // `response.url`。依赖该字段判断"重定向到哪个主机"的能力（如 Bing 翻译在大陆要改投
      // cn.bing.com）**在本平台无法实现**，Bing provider 已因此从可选列表移除。
      url: url,
      headers: this.responseHeaders(response.header),
      rid: rid,
    };
  }



  /**
   * 只含 EOF 标志的一块。**绝不能与正文同块**：plugin-http 的客户端是
   *   `if (lastByte === 1) controller.close(); else controller.enqueue(actualData)`
   * —— 标志为 1 时它 close 并**丢弃同块正文**。所以正文必须全部以 flag=0 发出，
   * 收尾再单独发这一个字节。同理，任何情况下都不许回空块：空块的末字节是
   * `undefined`（不等于 1），客户端会无限 pull → 界面永久转圈。
   */
  private httpEofChunk(): ESObject {
    const eof = new Uint8Array(1);
    eof[0] = 1;
    return { __readestBytes: new util.Base64Helper().encodeToStringSync(eof) };
  }

  private httpReadBody(args: ESObject): ESObject {
    const rid = this.argNumber(args, 'rid', -1);
    const body = this.httpBodies.get(rid);
    if (body === undefined) {
      // 未知/已释放的 rid：只回 EOF，让客户端干净收尾而不是挂死。
      this.destroyHttpClient(rid);
      return this.httpEofChunk();
    }
    const offset = this.httpOffsets.get(rid) || 0;
    if (offset >= body.length) {
      // 正文已发完，这一趟只发 EOF（正文部分为空，正是客户端期望的形状）。
      this.httpBodies.delete(rid);
      this.httpOffsets.delete(rid);
      // 成功路径的唯一回收点：plugin-http 读完 body 不会发 fetch_cancel。
      this.destroyHttpClient(rid);
      return this.httpEofChunk();
    }
    const chunkSize = 64 * 1024;
    const end = Math.min(body.length, offset + chunkSize);
    // flag 恒为 0：EOF 永不与正文同块，否则整块正文会被客户端丢掉
    //（症状：正文非空的响应变成空响应，订阅源因此报 "Unrecognized feed format"）。
    const chunk = new Uint8Array(end - offset + 1);
    chunk.set(body.subarray(offset, end), 0);
    chunk[end - offset] = 0;
    this.httpOffsets.set(rid, end);
    return { __readestBytes: new util.Base64Helper().encodeToStringSync(chunk) };
  }

  private httpCancel(args: ESObject): null {
    const rid = this.argNumber(args, 'rid', -1);
    this.destroyHttpClient(rid);
    this.httpBodies.delete(rid);
    this.httpOffsets.delete(rid);
    return null;
  }

  /**
   * 回收一个 http 客户端句柄。
   *
   * plugin-http 的成功路径**从不**发 `fetch_cancel`（读完 body 就 close 流），
   * 所以句柄只能由桥在"正文读完/请求失败"时自己回收 —— 否则每取一次资源漏一个
   * HttpRequest，越用越容易在 `fetch_send` 上随机失败。
   */
  private destroyHttpClient(rid: number): void {
    const client = this.httpClients.get(rid);
    if (client) {
      try { client.destroy(); } catch (error) {}
      this.httpClients.delete(rid);
    }
    this.httpConfigs.delete(rid);
  }

  private httpCancelBody(args: ESObject): null {
    const rid = this.argNumber(args, 'rid', -1);
    this.httpBodies.delete(rid);
    this.httpOffsets.delete(rid);
    return null;
  }


  private clipboardWriteText(args: ESObject): null {
    const text = this.argString(args, 'text');
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    // webapp 只用 write_text（复制按钮）。留一行诊断，便于人工点复制后核对是否真的落盘。
    this.diag('clipboard write len=' + text.length);
    return null;
  }

  private clipboardReadText(): string {
    try {
      const data = pasteboard.getSystemPasteboard().getDataSync();
      if (!data) {
        this.diag('clipboard read: no paste data');
        return '';
      }
      const primary: string = data.getPrimaryText();
      // getPrimaryText() 在无 TEXT_PLAIN 记录时返回 undefined；上游 webapp 从不调用
      // read_text，所以这里只记诊断，不做补偿。
      this.diag('clipboard read primary=' + (primary === undefined ? 'undefined' : String(primary).length + 'chars'));
      return primary;
    } catch (error) {
      this.diag('clipboard read failed: ' + String(error));
      hilog.warn(DOMAIN, TAG, 'clipboard read unavailable: %{public}s', String(error));
      return '';
    }
  }

  private clipboardClear(): null {
    try {
      pasteboard.getSystemPasteboard().clearDataSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clipboard clear failed: %{public}s', String(error));
    }
    return null;
  }

  private argPayload(args: ESObject): ESObject {
    const payload: ESObject = args ? args.payload : undefined;
    return payload ? payload : {};
  }

  private ttsInit(): ESObject {
    return new TtsInitResult(true);
  }

  private ttsFallbackVoices(): Array<TtsVoiceInfo> {
    // CoreSpeechKit ships three voices (per the docs); listVoices returns 401 on
    // this device, so list the known ones directly. person comes from the docs
    // (聆小珊=0, 凌飞哲=1, 英语劳拉=8).
    return [
      new TtsVoiceInfo('harmony_zh-CN_0', '聆小珊（女声·中文）', 'zh-CN', false),
      new TtsVoiceInfo('harmony_zh-CN_21', '凌飞哲（男声·中文）', 'zh-CN', false),
      new TtsVoiceInfo('harmony_en-US_8', 'Laura（女声·英语）', 'en-US', false),
    ];
  }

  private ttsGetAllVoices(): ESObject {
    return new TtsVoicesResult(this.ttsVoices.length > 0 ? this.ttsVoices : this.ttsFallbackVoices());
  }

  private async ttsInitAsync(): Promise<ESObject> {
    hilog.info(DOMAIN, TAG, 'native-tts init requested');
    await this.ttsRefreshVoices();
    hilog.info(DOMAIN, TAG, 'native-tts init complete, voices=%{public}d', this.ttsVoices.length);
    return new TtsInitResult(true);
  }

  private async ttsGetAllVoicesAsync(): Promise<ESObject> {
    if (this.ttsVoices.length === 0) {
      await this.ttsRefreshVoices();
    }
    return new TtsVoicesResult(this.ttsVoices.length > 0 ? this.ttsVoices : this.ttsFallbackVoices());
  }

  private async ttsRefreshVoices(): Promise<void> {
    try {
      const availableVoices = await textToSpeech.listVoices({
        requestId: util.generateRandomUUID(),
        online: 0,
      });
      const mappedVoices: Array<TtsVoiceInfo> = [];
      for (let i = 0; i < availableVoices.length; i++) {
        const voice = availableVoices[i];
        const normalizedLang = voice.language.split('_').join('-');
        const voiceName = voice.description && voice.description.length > 0 ? voice.description : normalizedLang;
        const voiceId = 'harmony_' + normalizedLang + '_' + voice.person;
        mappedVoices.push(new TtsVoiceInfo(voiceId, voiceName, normalizedLang, false));
      }
      if (mappedVoices.length > 0) {
        this.ttsVoices = mappedVoices;
      }
      hilog.info(DOMAIN, TAG, 'native-tts voices refreshed, count=%{public}d', this.ttsVoices.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'refresh text-to-speech voices failed: %{public}s', JSON.stringify(error));
    }
  }

  private ttsSetVoice(args: ESObject): null {
    const payload: ESObject = this.argPayload(args);
    const voiceId = this.argString(payload, 'voice');
    if (voiceId.length === 0) return null;
    this.ttsVoiceId = voiceId;
    const parts = voiceId.split('_');
    if (parts.length >= 2 && parts[1].length > 0) {
      const lang = parts[1];
      let person = 0;
      if (parts.length >= 3) {
        const parsed = Number(parts[2]);
        person = isNaN(parsed) ? 0 : parsed;
      }
      if (lang !== this.ttsVoiceLang || person !== this.ttsVoicePerson) {
        this.ttsVoiceLang = lang;
        this.ttsVoicePerson = person;
        this.ttsResetEngine();
      }
    }
    return null;
  }

  private ttsSetRate(args: ESObject): null {
    const payload: ESObject = this.argPayload(args);
    this.ttsRate = this.argNumber(payload, 'rate', 1.0);
    return null;
  }

  private ttsSetPitch(args: ESObject): null {
    const payload: ESObject = this.argPayload(args);
    this.ttsPitch = this.argNumber(payload, 'pitch', 1.0);
    return null;
  }

  private ttsSpeak(args: ESObject): ESObject {
    const payload: ESObject = this.argPayload(args);
    const text = this.argString(payload, 'text');
    const preload = payload['preload'] === true;
    const utteranceId = 'ohos-tts-' + this.ttsNextUtteranceId++;
    if (text.length === 0) {
      this.handleTtsEvent(utteranceId, 'error', 'empty text');
      return { utteranceId };
    }
    if (preload) {
      setTimeout(() => this.handleTtsEvent(utteranceId, 'end', 'preload'), 0);
      return { utteranceId };
    }
    hilog.info(DOMAIN, TAG, 'native-tts speak requested, utterance=%{public}s', utteranceId);
    this.ttsEnsureEngine().then((ready: boolean) => {
      if (!ready) {
        this.handleTtsEvent(utteranceId, 'error', 'Failed to initialize text-to-speech engine');
        return;
      }
      const engine = this.ttsEngine;
      if (!engine) {
        this.handleTtsEvent(utteranceId, 'error', 'Text-to-speech engine is unavailable');
        return;
      }
      try {
        const speakExtra: Record<string, Object> = {
          'queueMode': 0,
          'speed': this.ttsRate,
          'volume': 2,
          'pitch': 1,
          'languageContext': this.ttsVoiceLang,
          'audioType': 'pcm',
          'soundChannel': 1,
          'playType': 1
        };
        engine.speak(text, { requestId: utteranceId, extraParams: speakExtra });
      } catch (error) {
        this.handleTtsEvent(utteranceId, 'error', String(error));
      }
    }).catch((error: ESObject) => {
      this.handleTtsEvent(utteranceId, 'error', String(error));
    });
    return { utteranceId };
  }

  private ttsPause(): null {
    try {
      if (this.ttsEngine) this.ttsEngine.stop();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tts pause failed: %{public}s', String(error));
    }
    return null;
  }

  private ttsResume(): null {
    return null;
  }

  private ttsStop(): null {
    try {
      if (this.ttsEngine) this.ttsEngine.stop();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tts stop failed: %{public}s', String(error));
    }
    return null;
  }

  private ttsResetEngine(): void {
    this.ttsInitPromise = null;
    const engine = this.ttsEngine;
    this.ttsEngine = null;
    if (engine) {
      try {
        engine.shutdown();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'tts shutdown failed: %{public}s', String(error));
      }
    }
  }

  private ttsEnsureEngine(): Promise<boolean> {
    if (this.ttsEngine) return Promise.resolve(true);
    if (this.ttsInitPromise) return this.ttsInitPromise;
    this.ttsInitPromise = this.createTtsEngine();
    return this.ttsInitPromise;
  }

  // Some voices (e.g. 凌飞哲 male, person 21) ship as 'GA' and must be
  // downloaded before use (see the CoreSpeechKit "男声音色无效" FAQ).
  private async ensureVoiceDownloaded(language: string, person: number): Promise<void> {
    if (person <= 0) return;
    await new Promise<void>((resolve: () => void) => {
      let done = false;
      const finish = (): void => { if (!done) { done = true; resolve(); } };
      try {
        textToSpeech.downloadVoice(
          { requestId: util.generateRandomUUID(), language: language, person: person, style: 'interaction-broadcast' },
          (err: BusinessError, resp: textToSpeech.DownloadResponse) => {
            if (err || !resp) { hilog.warn(DOMAIN, TAG, 'downloadVoice failed person=%{public}d: %{public}s', person, String(err)); finish(); return; }
            resp.on('complete', () => { hilog.info(DOMAIN, TAG, 'downloadVoice complete person=%{public}d', person); finish(); });
            resp.on('error', (e: BusinessError) => { hilog.warn(DOMAIN, TAG, 'downloadVoice error: %{public}s', String(e)); finish(); });
            resp.on('cancel', () => { hilog.warn(DOMAIN, TAG, 'downloadVoice cancel person=%{public}d', person); finish(); });
            setTimeout(finish, 25000);
          });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'downloadVoice threw: %{public}s', String(e));
        finish();
      }
    });
  }

  private async createTtsEngine(): Promise<boolean> {
    // The TTS API wants a BCP-47-ish tag like 'zh-CN' (hyphen), NOT 'zh_CN'.
    const apiLanguage = this.ttsVoiceLang.split('_').join('-');
    let language = apiLanguage;
    let person = this.ttsVoicePerson; // the user-selected voice's person
    let online = 1;
    try {
      const availableVoices = await textToSpeech.listVoices({
        requestId: util.generateRandomUUID(),
        online: online,
      });
      if (availableVoices.length > 0) {
        let selected = availableVoices[0];
        for (let i = 0; i < availableVoices.length; i++) {
          if (availableVoices[i].language.split('_').join('-') === apiLanguage) {
            selected = availableVoices[i];
            break;
          }
        }
        language = selected.language.split('_').join('-');
        person = selected.person;
      }
    } catch (listError) {
      hilog.warn(DOMAIN, TAG, 'list text-to-speech voices failed: %{public}s', JSON.stringify(listError));
    }

    await this.ensureVoiceDownloaded(language, person);
    try {
      const initExtra: Record<string, Object> = { 'style': 'interaction-broadcast', 'locate': 'CN', 'name': 'ReadestTTS' };
      const engine = await textToSpeech.createEngine({ language: language, person: person, online: online, extraParams: initExtra });
      engine.setListener(new ReadestTtsListener(this));
      this.ttsEngine = engine;
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'create text-to-speech engine failed (online=%{public}d person=%{public}d lang=%{public}s): %{public}s',
        online, person, language, JSON.stringify(error));
    }

    try {
      const fallback = await textToSpeech.createEngine({ language: 'zh-CN', person: this.ttsVoicePerson, online: 1 });
      fallback.setListener(new ReadestTtsListener(this));
      this.ttsEngine = fallback;
      return true;
    } catch (fallbackError) {
      hilog.warn(DOMAIN, TAG, 'fallback text-to-speech engine failed: %{public}s', JSON.stringify(fallbackError));
    }

    this.ttsInitPromise = null;
    return false;
  }

  private ttsPlayoutDir(): string {
    if (!this.context) return '';
    return `${this.context.cacheDir}/tts-playout`;
  }

  private ttsPlayoutFilePath(session: number, index: number): string {
    return `${this.ttsPlayoutDir()}/${session}_${index}.mp3`;
  }

  private ttsPlayoutEnsureDir(): void {
    const dir = this.ttsPlayoutDir();
    if (dir.length > 0 && !fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      fs.mkdirSync(dir, true);
    }
  }

  private ttsPlayoutEmit(type: string, index: number): void {
    this.emitPluginEvent('native-tts', 'playout_events', {
      type: type,
      session: this.ttsPlayoutSession,
      index: index,
    });
  }

  private ttsPlayoutSpeed(rate: number): media.PlaybackSpeed {
    if (rate <= 0.125) return media.PlaybackSpeed.SPEED_FORWARD_0_125_X;
    if (rate <= 0.25) return media.PlaybackSpeed.SPEED_FORWARD_0_25_X;
    if (rate <= 0.5) return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    if (rate <= 0.75) return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    if (rate <= 1.0) return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (rate <= 1.25) return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    if (rate <= 1.5) return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    if (rate <= 1.75) return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    if (rate <= 2.0) return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
  }

  private ttsPlayoutReleaseItem(item: TtsPlayoutItem): void {
    const player = item.player;
    item.player = null;
    if (player) {
      player.release().then(() => {}).catch((_error: BusinessError) => {});
    }
    if (item.fd >= 0) {
      try {
        fs.closeSync(item.fd);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'tts playout close fd failed: %{public}s', String(error));
      }
      item.fd = -1;
    }
    if (item.ownsFile) {
      try {
        if (fs.accessSync(item.filePath, fs.AccessModeType.EXIST)) {
          fs.unlinkSync(item.filePath);
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'tts playout unlink failed: %{public}s', String(error));
      }
    }
  }

  private ttsPlayoutAbort(): void {
    const items = this.ttsPlayoutQueue;
    this.ttsPlayoutQueue = [];
    for (let i = 0; i < items.length; i++) {
      this.ttsPlayoutReleaseItem(items[i]);
    }
    const current = this.ttsPlayoutCurrentItem;
    if (current) {
      this.ttsPlayoutReleaseItem(current);
    }
    this.ttsPlayoutCurrentItem = null;
    this.ttsPlayoutCurrentPlayer = null;
    this.ttsPlayoutCurrentIndex = -1;
    this.ttsPlayoutNextIndex = 0;
    this.ttsPlayoutEndRequested = false;
  }

  private ttsPlayoutNextItem(): TtsPlayoutItem | null {
    for (let i = 0; i < this.ttsPlayoutQueue.length; i++) {
      const item = this.ttsPlayoutQueue[i];
      if (!item.started && item.index === this.ttsPlayoutNextIndex) {
        return item;
      }
    }
    return null;
  }

  private async ttsPlayoutStartNext(): Promise<void> {
    if (this.ttsPlayoutCurrentPlayer) return;
    const item = this.ttsPlayoutNextItem();
    if (!item) {
      if (this.ttsPlayoutEndRequested) {
        this.ttsPlayoutEndRequested = false;
        this.ttsPlayoutEmit('session-end', this.ttsPlayoutCurrentIndex);
      }
      return;
    }
    const player = item.player;
    if (!player) return;
    item.started = true;
    this.ttsPlayoutCurrentItem = item;
    this.ttsPlayoutCurrentPlayer = player;
    this.ttsPlayoutCurrentIndex = item.index;
    this.ttsPlayoutNextIndex = item.index + 1;
    try {
      player.setSpeed(this.ttsPlayoutSpeed(this.ttsPlayoutRate));
      await player.play();
      this.ttsPlayoutEmit('chunk-start', item.index);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tts playout start failed: %{public}s', String(error));
      this.ttsPlayoutEmit('error', item.index);
      this.ttsPlayoutReleaseItem(item);
      this.ttsPlayoutCurrentItem = null;
      this.ttsPlayoutCurrentPlayer = null;
      this.ttsPlayoutStartNext();
    }
  }

  private ttsPlayoutOnCompleted(item: TtsPlayoutItem): void {
    if (this.ttsPlayoutCurrentItem !== item) return;
    this.ttsPlayoutReleaseItem(item);
    this.ttsPlayoutCurrentItem = null;
    this.ttsPlayoutCurrentPlayer = null;
    this.ttsPlayoutCurrentIndex = -1;
    if (item.singleFile) {
      // Media Overlay: the whole file finished. Signal 'ended' so the client
      // advances to the next clip/section; there is no queue to continue.
      this.ttsPlayoutEmit('ended', item.index);
      return;
    }
    const gapMs = item.gapMs > 0 ? item.gapMs : 0;
    setTimeout(() => {
      this.ttsPlayoutStartNext();
    }, gapMs);
  }

  private async ttsPlayoutControl(args: ESObject): Promise<ESObject> {
    const payload: ESObject = this.argPayload(args);
    const action = this.argString(payload, 'action');
    if (action === 'start-session') {
      this.ttsPlayoutAbort();
      this.ttsPlayoutSession++;
      this.ttsPlayoutEndRequested = false;
      return { session: this.ttsPlayoutSession };
    }
    if (action === 'end-session') {
      this.ttsPlayoutEndRequested = true;
      if (!this.ttsPlayoutCurrentPlayer) {
        this.ttsPlayoutStartNext();
      }
      return { session: null };
    }
    if (action === 'abort') {
      this.ttsPlayoutAbort();
      return { session: null };
    }
    if (action === 'pause') {
      if (this.ttsPlayoutCurrentPlayer) {
        this.ttsPlayoutCurrentPlayer.pause();
      }
      return { session: null };
    }
    if (action === 'resume') {
      if (this.ttsPlayoutCurrentPlayer) {
        this.ttsPlayoutCurrentPlayer.play();
      }
      return { session: null };
    }
    if (action === 'set-rate') {
      this.ttsPlayoutRate = this.argNumber(payload, 'rate', 1.0);
      if (this.ttsPlayoutCurrentPlayer) {
        this.ttsPlayoutCurrentPlayer.setSpeed(this.ttsPlayoutSpeed(this.ttsPlayoutRate));
      }
      return { session: null };
    }
    if (action === 'seek') {
      const seekMs = this.argNumber(payload, 'positionMs', 0);
      const player = this.ttsPlayoutCurrentPlayer;
      if (player && seekMs >= 0) {
        try {
          player.seek(seekMs);
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'tts playout seek failed: %{public}s', String(error));
        }
      }
      return { session: null };
    }
    if (action === 'load') {
      await this.ttsPlayoutLoad(payload);
      return { session: null };
    }
    throw new Error('unsupported playout action: ' + action);
  }

  /**
   * AVPlayer reaches `initialized` ASYNCHRONOUSLY after fdSrc is assigned;
   * prepare() only accepts stopped/initialized. Assigning fdSrc and calling
   * prepare() back-to-back throws "The current state is idle", so wait for
   * the transition (state is checked first in case the callback already
   * fired).
   */
  private avPlayerAwaitInitialized(player: media.AVPlayer): Promise<void> {
    if (player.state === 'initialized') return Promise.resolve();
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      const onState = (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
        if (state === 'initialized') {
          player.off('stateChange', onState);
          resolve();
        } else if (state === 'error') {
          player.off('stateChange', onState);
          reject(new Error('avplayer source failed before prepare'));
        }
      };
      player.on('stateChange', onState);
    });
  }

  // Media Overlay: load a continuous audio file (the JS side owns the file),
  // seek to the start offset, and leave it prepared-but-paused. The client
  // drives playback with resume/pause/seek and reads position via
  // playout_position. Completion fires a single 'ended' event.
  private async ttsPlayoutLoad(payload: ESObject): Promise<void> {
    const path = this.argString(payload, 'path');
    const positionMs = this.argNumber(payload, 'positionMs', 0);
    if (path.length === 0) {
      this.ttsPlayoutEmit('error', -1);
      return;
    }
    // Any previous chunk queue / single-file item is done.
    this.ttsPlayoutAbort();
    const item = new TtsPlayoutItem(this.ttsPlayoutSession, 0, path, 0);
    item.singleFile = true;
    item.ownsFile = false; // JS owns this file (staged temp or Books/<hash>)
    try {
      const fdFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
      item.fd = fdFile.fd;
      const stat = fs.statSync(path);
      const descriptor: media.AVFileDescriptor = { fd: fdFile.fd, offset: 0, length: stat.size };
      const player = await media.createAVPlayer();
      item.player = player;
      player.fdSrc = descriptor;
      player.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason) => {
        if (state === 'completed') {
          this.ttsPlayoutOnCompleted(item);
        } else if (state === 'error') {
          this.ttsPlayoutEmit('error', item.index);
          if (this.ttsPlayoutCurrentItem === item) {
            this.ttsPlayoutCurrentItem = null;
            this.ttsPlayoutCurrentPlayer = null;
            this.ttsPlayoutCurrentIndex = -1;
          }
          this.ttsPlayoutReleaseItem(item);
        }
      });
      player.on('error', (_error: BusinessError) => {
        this.ttsPlayoutEmit('error', item.index);
        if (this.ttsPlayoutCurrentItem === item) {
          this.ttsPlayoutCurrentItem = null;
          this.ttsPlayoutCurrentPlayer = null;
          this.ttsPlayoutCurrentIndex = -1;
        }
        this.ttsPlayoutReleaseItem(item);
      });
      await this.avPlayerAwaitInitialized(player);
      await player.prepare();
      item.durationMs = player.duration;
      try {
        player.setSpeed(this.ttsPlayoutSpeed(this.ttsPlayoutRate));
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'tts playout load setSpeed failed: %{public}s', String(error));
      }
      if (positionMs > 0) {
        try {
          player.seek(positionMs);
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'tts playout load seek failed: %{public}s', String(error));
        }
      }
      this.ttsPlayoutCurrentItem = item;
      this.ttsPlayoutCurrentPlayer = player;
      this.ttsPlayoutCurrentIndex = item.index;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tts playout load failed: %{public}s', String(error));
      this.ttsPlayoutEmit('error', -1);
      this.ttsPlayoutReleaseItem(item);
    }
  }

  private async ttsPlayoutEnqueue(args: ESObject): Promise<ESObject> {
    const payload: ESObject = this.argPayload(args);
    const session = this.argNumber(payload, 'session', -1);
    const index = this.argNumber(payload, 'index', -1);
    const data = this.argString(payload, 'data');
    const gapMs = this.argNumber(payload, 'gapMs', 0);
    if (session !== this.ttsPlayoutSession || index < 0 || data.length === 0) {
      return { durationMs: 0 };
    }
    this.ttsPlayoutEnsureDir();
    const filePath = this.ttsPlayoutFilePath(session, index);
    const bytes = new util.Base64Helper().decodeSync(data);
    const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
    const item = new TtsPlayoutItem(session, index, filePath, gapMs);
    const player = await media.createAVPlayer();
    const fdFile = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(filePath);
    const descriptor: media.AVFileDescriptor = { fd: fdFile.fd, offset: 0, length: stat.size };
    player.fdSrc = descriptor;
    player.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason) => {
      if (state === 'completed') {
        this.ttsPlayoutOnCompleted(item);
      } else if (state === 'error') {
        this.ttsPlayoutEmit('error', index);
        this.ttsPlayoutReleaseItem(item);
      }
    });
    player.on('error', (_error: BusinessError) => {
      this.ttsPlayoutEmit('error', index);
      this.ttsPlayoutReleaseItem(item);
    });
    await this.avPlayerAwaitInitialized(player);
    await player.prepare();
    item.durationMs = player.duration;
    item.fd = fdFile.fd;
    item.player = player;
    this.ttsPlayoutQueue.push(item);
    if (!this.ttsPlayoutCurrentPlayer) {
      await this.ttsPlayoutStartNext();
    }
    return { durationMs: item.durationMs };
  }

  private async ttsPlayoutPosition(): Promise<ESObject> {
    const player = this.ttsPlayoutCurrentPlayer;
    return {
      session: this.ttsPlayoutSession,
      index: this.ttsPlayoutCurrentIndex,
      positionMs: player ? player.currentTime : 0,
      playing: player ? player.state === 'playing' : false,
    };
  }

  private async ttsEnsureAvSession(): Promise<avSession.AVSession | null> {
    if (this.ttsAvSession) return this.ttsAvSession;
    if (!this.context) return null;
    try {
      const session = await avSession.createAVSession(this.context, 'Readest', 'audio');
      session.on('play', () => {
        this.emitPluginEvent('native-tts', 'media-session-play', {});
      });
      session.on('pause', () => {
        this.emitPluginEvent('native-tts', 'media-session-pause', {});
      });
      session.on('stop', () => {
        this.emitPluginEvent('native-tts', 'media-session-toggle', {});
      });
      session.on('playNext', () => {
        this.emitPluginEvent('native-tts', 'media-session-next', {});
      });
      session.on('playPrevious', () => {
        this.emitPluginEvent('native-tts', 'media-session-previous', {});
      });
      session.on('fastForward', () => {
        this.emitPluginEvent('native-tts', 'media-session-seek-forward', {});
      });
      session.on('rewind', () => {
        this.emitPluginEvent('native-tts', 'media-session-seek-backward', {});
      });
      session.on('seek', (time: number) => {
        this.emitPluginEvent('native-tts', 'media-session-seek', { position: time });
      });
      this.ttsAvSession = session;
      return session;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'create AVSession failed: %{public}s', JSON.stringify(error));
      return null;
    }
  }

  private async ttsMediaSetActive(args: ESObject): Promise<ESObject> {
    const payload: ESObject = this.argPayload(args);
    const active = payload['active'] === true;
    const session = await this.ttsEnsureAvSession();
    hilog.info(DOMAIN, TAG, 'media-session setActive active=%{public}s hasSession=%{public}s',
      String(active), String(!!session));
    if (session) {
      if (active) {
        await session.activate();
      } else {
        await session.deactivate();
      }
    }
    return null;
  }

  private async ttsMediaUpdateMetadata(args: ESObject): Promise<ESObject> {
    const payload: ESObject = this.argPayload(args);
    const session = await this.ttsEnsureAvSession();
    if (!session) return null;
    const sessionId = this.argString(payload, 'sessionId');
    const metadata: avSession.AVMetadata = {
      assetId: sessionId.length > 0 ? sessionId : 'readest-tts',
      title: this.argString(payload, 'title'),
      artist: this.argString(payload, 'artist'),
      album: this.argString(payload, 'album'),
    };
    const artwork = this.argString(payload, 'artwork');
    if (artwork.length > 0) {
      metadata.mediaImage = artwork;
    }
    await session.setAVMetadata(metadata);
    hilog.info(DOMAIN, TAG, 'media-session metadata title=%{public}s artist=%{public}s hasArtwork=%{public}s',
      metadata.title, metadata.artist, String(artwork.length > 0));
    return null;
  }

  private async ttsMediaUpdateState(args: ESObject): Promise<ESObject> {
    const payload: ESObject = this.argPayload(args);
    const session = await this.ttsEnsureAvSession();
    if (!session) return null;
    const playbackState: avSession.AVPlaybackState = {
      state: payload['playing'] === true
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1.0,
    };
    const positionMs = this.argNumber(payload, 'position', 0);
    playbackState.position = {
      elapsedTime: positionMs,
      updateTime: Date.now(),
    };
    const durationMs = this.argNumber(payload, 'duration', 0);
    if (durationMs > 0) {
      playbackState.bufferedTime = durationMs;
    }
    await session.setAVPlaybackState(playbackState);
    hilog.info(DOMAIN, TAG, 'media-session state playing=%{public}s posMs=%{public}d durMs=%{public}d',
      String(payload['playing'] === true), positionMs, durationMs);
    return null;
  }

  handleTtsEvent(utteranceId: string, code: string, message: string): void {
    this.emitPluginEvent('native-tts', 'tts_events', {
      utteranceId: utteranceId,
      code: code,
      message: message,
    });
  }

  /**
   * Window-scoped event (Tauri's window.emit). The webapp subscribes through
   * getCurrentWindow().listen()/plugin:event|listen; readest-bridge.js routes
   * __READEST_BRIDGE__.emit to those listeners. Used for
   * 'web-browser-download', which useWebBrowserDownloads' non-mobile branch
   * (the one Harmony takes, isMobileApp=false) expects as a window event.
   */
  private emitWindowEvent(event: string, payload: ESObject): void {
    if (!this.controller) return;
    try {
      const script = 'window.__READEST_BRIDGE__ && window.__READEST_BRIDGE__.emit(' +
        JSON.stringify(event) + ', ' + JSON.stringify(payload) + ');';
      this.controller.runJavaScript(script);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'emit window event failed: %{public}s', String(error));
    }
  }

  /**
   * Emit a `web-browser-download` event (wire shape of
   * services/webBrowser/webBrowser.ts::WebBrowserDownload). Called by
   * Index.ets from the in-app browser's WebDownloadDelegate. `path` is the
   * absolute sandbox path the archive landed in.
   */
  emitWebBrowserDownload(url: string, path: string, filename: string, success: boolean, errorText: string): void {
    this.lastDownloadPath = path;
    hilog.info(DOMAIN, TAG, 'web-browser-download success=%{public}s file=%{public}s', String(success), filename);
    this.diag('emit web-browser-download success=' + String(success) + ' file=' + filename + ' path=' + path);
    this.emitWindowEvent('web-browser-download', {
      url: url,
      path: path,
      filename: filename,
      success: success,
      error: success ? '' : errorText,
    });
  }

  /**
   * Relay the webapp's browser-download status to the in-app browser UI, which
   * uses it to close the overlay once the book is really in the library.
   */
  private relayWebBrowserStatus(args: ESObject): void {
    if (!this.importStatusSink) return;
    const status: ESObject = args ? args['status'] : undefined;
    if (status === undefined || status === null) return;
    const state = String(status['state'] === undefined ? '' : status['state']);
    if (state !== 'added' && state !== 'importing' && state !== 'failed' && state !== 'unsupported') return;
    const filename = String(status['filename'] === undefined ? '' : status['filename']);
    this.importStatusSink(state, filename);
  }

  /**
   * Download `url` to an absolute sandbox `path` with the platform HTTP
   * stack. Used by the in-app browser: this app's Web is CEF-backed and
   * does NOT fire ArkWeb's WebDownloadDelegate for page downloads, so the
   * browser intercepts book-archive navigations (Index.ets) and downloads
   * them here, then emits `web-browser-download` itself.
   */
  async downloadToFile(url: string, path: string): Promise<void> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        readTimeout: 120000,
        connectTimeout: 30000,
      });
      if (response.responseCode !== 200) {
        throw new Error('http status ' + String(response.responseCode));
      }
      const buffer = response.result as ArrayBuffer;
      this.diag('download url=' + url + ' status=' + String(response.responseCode) +
        ' bytes=' + String(buffer.byteLength));
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (error) {
      this.diag('download FAILED url=' + url + ' err=' + String(error));
      // ArkTS 不允许 throw 任意类型的值（arkts-limited-throw），必须包成 Error。
      throw new Error(String(error));
    } finally {
      client.destroy();
    }
  }

  /** File name for a download URL: last path segment, percent-decoded. */
  suggestedFileName(url: string): string {
    let pathPart = url.split('?')[0].split('#')[0];
    const slash = pathPart.lastIndexOf('/');
    pathPart = slash >= 0 ? pathPart.substring(slash + 1) : pathPart;
    try {
      const name = decodeURIComponent(pathPart);
      return name.length > 0 ? name : 'download.bin';
    } catch (_error) {
      return pathPart.length > 0 ? pathPart : 'download.bin';
    }
  }

  /** Sandbox dir the in-app browser saves downloads into. */
  browserDownloadsDir(): string {
    const root = this.context ? this.context.cacheDir : '/data/storage/el2/base/cache';
    const dir = root + '/web-downloads';
    if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      try {
        fs.mkdirSync(dir, true);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'web-downloads mkdir failed: %{public}s', String(error));
      }
    }
    return dir;
  }

  /**
   * extract_web_browser_archive: unpack a downloaded book archive with the
   * platform ZIP/inflate (@ohos.zlib.decompressFile) and return the absolute
   * paths of the book files inside, filtered by the extension list the JS
   * side passes (SUPPORTED_BOOK_EXTS minus zip/txt/md).
   *
   * Any failure — a book saved under a .zip name, a corrupt archive, a "../"
   * path-traversal entry — returns an EMPTY list on purpose: the JS then
   * imports the download itself, which is the correct outcome for a renamed
   * book and a clean "nothing importable" for the rest.
   */
  private async webBrowserArchiveExtract(args: ESObject): Promise<ESObject> {
    const path = this.argString(args, 'path');
    if (path.length === 0) return [] as Array<string>;
    const extsRaw: ESObject = args['exts'];
    const exts = new Set<string>();
    if (Array.isArray(extsRaw)) {
      const list: Array<string> = extsRaw as Array<string>;
      for (let i = 0; i < list.length; i++) {
        const ext = String(list[i]).toLowerCase().replace(/^\./, '');
        if (ext.length > 0) exts.add(ext);
      }
    }
    if (exts.size === 0) return [] as Array<string>;

    const outDir = this.webBrowserArchiveDir(path);
    if (!fs.accessSync(outDir, fs.AccessModeType.EXIST)) {
      try {
        fs.mkdirSync(outDir, true);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'web-archive mkdir failed: %{public}s', String(error));
        return [] as Array<string>;
      }
    }
    try {
      await new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
        zlib.decompressFile(path, outDir, {
          level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
          memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
          strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY,
        }, (error: BusinessError) => {
          if (error) {
            reject(new Error('decompressFile failed code=' + String(error.code)));
          } else {
            resolve();
          }
        });
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'web browser archive extract failed: %{public}s', String(error));
      this.diag('extract FAILED path=' + path + ' err=' + String(error));
      return [] as Array<string>;
    }

    // Walk the extraction dir, collecting book files by extension.
    const books: Array<string> = [];
    const stack: Array<string> = [outDir];
    while (stack.length > 0) {
      const dir = stack.pop() as string;
      let names: Array<string> = [];
      try {
        names = fs.listFileSync(dir);
      } catch (_error) {
        continue;
      }
      for (let i = 0; i < names.length; i++) {
        const full = dir + '/' + names[i];
        try {
          const stat = fs.statSync(full);
          if (stat.isDirectory()) {
            stack.push(full);
          } else {
            const dot = full.lastIndexOf('.');
            if (dot >= 0 && exts.has(full.slice(dot + 1).toLowerCase())) {
              books.push(full);
            }
          }
        } catch (_error) {
          // Entry vanished mid-walk; skip it.
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'web browser archive extracted books=%{public}d dir=%{public}s', books.length, outDir);
    this.diag('extract done books=' + String(books.length) + ' dir=' + outDir +
      (books.length > 0 ? ' first=' + books[0] : ''));
    return books;
  }

  /** Per-archive extraction dir: hash of the source path + a timestamp, so
   *  repeated downloads of the same URL never collide. Old dirs stay in
   *  cache for the OS to reclaim. */
  /**
   * Deletion half of the in-app-browser download flow. A finished download and
   * its unpacked archive are pure intermediates once the webapp has imported
   * the book (ingestFile copies the book into Books/<hash>/), so leaving them in
   * the cache only grows it: on 2026-09-26 the cache held ~20 MB of leftovers.
   * Deletion MUST happen after the `added` report, never before.
   */
  removePath(path: string): void {
    if (path.length === 0) return;
    try {
      const stat = fs.statSync(path);
      if (stat.isDirectory()) {
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (_error) {
      // Already gone, or the unpacked tree is still being read: harmless.
    }
  }

  /** Entries of a cache directory, `[]` when it does not exist. */
  listCacheDir(dir: string): Array<string> {
    try {
      if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) return [] as Array<string>;
      return fs.listFileSync(dir, { recursion: false });
    } catch (_error) {
      return [] as Array<string>;
    }
  }

  /** Last modification time in ms, 0 when unknown. */
  pathMtimeMs(path: string): number {
    try {
      return fs.statSync(path).mtime;
    } catch (_error) {
      return 0;
    }
  }

  /** Root of the download staging area and of the unpack dirs. */
  browserCacheRoot(): string {
    return this.context ? this.context.cacheDir : '/data/storage/el2/base/cache';
  }

  webBrowserArchiveDir(path: string): string {
    const base = path + ':' + Date.now();
    let h = 0;
    for (let i = 0; i < base.length; i++) {
      h = (h * 31 + base.charCodeAt(i)) | 0;
    }
    const root = this.context ? this.context.cacheDir : '/data/storage/el2/base/cache';
    return root + '/web-archive-' + (h >>> 0).toString(16);
  }

  private emitPluginEvent(plugin: string, event: string, payload: ESObject): void {
    if (!this.controller) return;
    try {
      const script = `window.__READEST_BRIDGE__ && window.__READEST_BRIDGE__.emitPlugin(${JSON.stringify(plugin)}, ${JSON.stringify(event)}, ${JSON.stringify(payload)});`;
      this.controller.runJavaScript(script);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'emit plugin event failed: %{public}s', String(error));
    }
  }

  private processExit(): null {
    if (this.context) {
      this.context.terminateSelf().catch((error: ESObject) => {
        hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', String(error));
      });
    }
    return null;
  }

  private processRestart(): null {
    if (this.context) {
      const want: ESObject = {
        bundleName: 'com.kehahn.readest',
        abilityName: 'EntryAbility',
      };
      this.context.restartApp(want).catch((error: ESObject) => {
        hilog.warn(DOMAIN, TAG, 'restartApp failed: %{public}s', String(error));
      });
    }
    return null;
  }


  private openerOpenUrl(args: ESObject): null {
    const url = this.argString(args, 'url');
    if (url.length === 0 || !this.context) return null;
    try {
      const context = this.context as common.UIAbilityContext;
      const options: OpenLinkOptions = { appLinkingOnly: false };
      context.openLink(url, options).catch((error: ESObject) => {
        hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', String(error));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'openLink threw: %{public}s', String(error));
    }
    return null;
  }


  private tursoPath(args: ESObject): string {
    const options: ESObject = args ? args.options : undefined;
    if (typeof options === 'string') return options;
    if (options && options.path) return String(options.path);
    return '';
  }

  private tursoDb(args: ESObject): string {
    return args ? String(args.db || '') : '';
  }

  private tursoStore(db: string): relationalStore.RdbStore {
    const store = this.rdbStores.get(db);
    if (!store) throw new Error('database not loaded: ' + db);
    return store;
  }

  private rdbValues(values: ESObject): Array<relationalStore.ValueType> {
    const result: Array<relationalStore.ValueType> = [];
    if (!Array.isArray(values)) return result;
    const arr: Array<ESObject> = values as Array<ESObject>;
    for (let i = 0; i < arr.length; i++) {
      const v: ESObject = arr[i];
      if (v === undefined || v === null) {
        result.push(null);
      } else if (Array.isArray(v)) {
        const bytes = new Uint8Array(v.length);
        for (let j = 0; j < v.length; j++) bytes[j] = Number(v[j]) & 0xff;
        result.push(bytes);
      } else if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') {
        result.push(v as relationalStore.ValueType);
      } else {
        result.push(String(v));
      }
    }
    return result;
  }

  private rdbValue(value: relationalStore.ValueType): ESObject {
    if (value === null || value === undefined) return null;
    if (value instanceof Uint8Array) {
      const bytes: Array<number> = [];
      const arr: Uint8Array = value;
      for (let i = 0; i < arr.length; i++) bytes.push(arr[i]);
      return bytes;
    }
    return value as ESObject;
  }

  private async tursoLoad(args: ESObject): Promise<string> {
    if (!this.context) throw new Error('context not ready');
    const path = this.tursoPath(args);
    if (path.length === 0) throw new Error('missing database path');
    if (this.rdbStores.has(path)) return path;
    const fileBase = path.replace(/^sqlite:/, '').replace(/[\\/:*?"<>|]/g, '_');
    const dbName = fileBase.length > 0 ? fileBase : 'readest_db';
    const config: relationalStore.StoreConfig = {
      name: dbName,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    const store = await relationalStore.getRdbStore(this.context, config);
    this.rdbStores.set(path, store);
    return path;
  }

  private async tursoExecute(args: ESObject): Promise<ESObject> {
    const db = this.tursoDb(args);
    const store = this.tursoStore(db);
    const query = this.argString(args, 'query');
    const values = this.rdbValues(args ? args.values : undefined);
    await store.executeSql(query, values);
    return { rowsAffected: 0, lastInsertId: 0 };
  }

  private async tursoSelect(args: ESObject): Promise<ESObject> {
    const db = this.tursoDb(args);
    const store = this.tursoStore(db);
    const query = this.argString(args, 'query');
    const values = this.rdbValues(args ? args.values : undefined);
    const rs: relationalStore.ResultSet = await store.querySql(query, values);
    const rows: Array<ESObject> = [];
    try {
      while (rs.goToNextRow()) {
        const row: ESObject = {};
        const columns: Array<string> = rs.columnNames;
        for (let i = 0; i < columns.length; i++) {
          row[columns[i]] = this.rdbValue(rs.getValue(i));
        }
        rows.push(row);
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  private async tursoBatch(args: ESObject): Promise<null> {
    const db = this.tursoDb(args);
    const store = this.tursoStore(db);
    const queries: ESObject = args ? args.queries : undefined;
    store.beginTransaction();
    try {
      if (Array.isArray(queries)) {
        const list = queries as Array<string>;
        for (let i = 0; i < list.length; i++) {
          await store.executeSql(String(list[i]), []);
        }
      }
      store.commit();
    } catch (error) {
      store.rollBack();
      throw new Error(String(error));
    }
    return null;
  }

  private async tursoClose(args: ESObject): Promise<boolean> {
    const db = this.tursoDb(args);
    if (db.length > 0) {
      const store = this.rdbStores.get(db);
      if (store) {
        await store.close();
        this.rdbStores.delete(db);
      }
    } else {
      const keys = Array.from(this.rdbStores.keys());
      for (let i = 0; i < keys.length; i++) {
        const store = this.rdbStores.get(keys[i]);
        if (store) await store.close();
      }
      this.rdbStores.clear();
    }
    return true;
  }

  // ── static assets / rangefile ────────────────────────────────────────

  private mimeOf(path: string): string {
    const p = path.toLowerCase();
    if (p.endsWith('.html')) return 'text/html';
    if (p.endsWith('.js') || p.endsWith('.mjs')) return 'text/javascript';
    if (p.endsWith('.css')) return 'text/css';
    if (p.endsWith('.json')) return 'application/json';
    // Next.js App Router static export stores its RSC navigation payloads in
    // .txt files. The client router only accepts them when the response
    // Content-Type is text/x-component.
    if (p.endsWith('.txt')) return 'text/x-component';
    if (p.endsWith('.wasm')) return 'application/wasm';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.woff')) return 'font/woff';
    if (p.endsWith('.woff2')) return 'font/woff2';
    if (p.endsWith('.ttf')) return 'font/ttf';
    if (p.endsWith('.pdf')) return 'application/pdf';
    if (p.endsWith('.epub')) return 'application/epub+zip';
    return 'application/octet-stream';
  }

  private header(key: string, value: string): Header {
    return { headerKey: key, headerValue: value };
  }

  private response(code: number, mime: string, data: string | ArrayBuffer,
    headers: Array<Header>): WebResourceResponse {
    const response = new WebResourceResponse();
    response.setResponseCode(code);
    response.setResponseMimeType(mime);
    response.setResponseEncoding('utf-8');
    response.setResponseData(data);
    response.setResponseHeader(headers);
    return response;
  }

  private serveAppAsset(rawUrl: string): WebResourceResponse {
    let path = rawUrl.replace(/^https?:\/\/appassets\.local/, '');
    const query = path.indexOf('?');
    if (query >= 0) path = path.substring(0, query);
    const hash = path.indexOf('#');
    if (hash >= 0) path = path.substring(0, hash);
    if (path.length === 0 || path === '/') path = '/index.html';
    try {
      const bytes = this.readRawAsset(path);
      return this.response(200, this.mimeOf(path), bytes.buffer as ArrayBuffer, [
        this.header('Cache-Control', 'no-store'),
        this.header('Cross-Origin-Opener-Policy', 'same-origin'),
        this.header('Cross-Origin-Embedder-Policy', 'require-corp'),
      ]);
    } catch (error) {
      return this.response(404, 'text/plain', 'Not found: ' + path, [
        this.header('Cache-Control', 'no-store'),
      ]);
    }
  }

  private readRawAsset(path: string): Uint8Array {
    if (!this.context) throw new Error('context not ready');
    const candidates: Array<string> = [];
    const raw = `webapp${path}`;
    candidates.push(raw);
    if (!path.endsWith('/')) {
      candidates.push(`${raw}.html`);
      candidates.push(`${raw}/index.html`);
    }
    let lastError: string = 'raw asset not found';
    for (let i = 0; i < candidates.length; i++) {
      try {
        return this.context.resourceManager.getRawFileContentSync(candidates[i]);
      } catch (error) {
        lastError = String(error);
      }
    }
    throw new Error(lastError);
  }

  private parseQuery(url: string): Map<string, string> {
    const result = new Map<string, string>();
    const index = url.indexOf('?');
    if (index < 0) return result;
    const query = url.substring(index + 1);
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const pair = parts[i].split('=');
      if (pair.length === 2) {
        result.set(pair[0], decodeURIComponent(pair[1]));
      }
    }
    return result;
  }

  private serveLocalFile(rawUrl: string, method: string): WebResourceResponse {
    const query = this.parseQuery(rawUrl);
    const filePath = query.get('path') || '';
    if (filePath.length === 0) {
      return this.response(400, 'text/plain', 'missing path', []);
    }
    try {
      const stat = fs.statSync(filePath);
      const total = stat.size;
      const hasRange = query.has('start') && query.has('end');
      const start = hasRange ? Number(query.get('start')) : 0;
      const end = hasRange ? Number(query.get('end')) : total - 1;
      const actualStart = Math.max(0, start);
      const actualEnd = Math.min(total - 1, end);
      if (method === 'HEAD') {
        return this.response(200, this.mimeOf(filePath), new ArrayBuffer(0), [
          this.header('X-Total-Size', String(total)),
          this.header('Content-Length', String(total)),
          this.header('Access-Control-Allow-Origin', '*'),
          this.header('Access-Control-Expose-Headers', 'X-Total-Size, Content-Type, Content-Length, Content-Range'),
        ]);
      }
      if (actualEnd < actualStart) {
        return this.response(200, this.mimeOf(filePath), new ArrayBuffer(0), [
          this.header('X-Total-Size', String(total)),
          this.header('Content-Length', '0'),
          this.header('Access-Control-Allow-Origin', '*'),
          this.header('Access-Control-Expose-Headers', 'X-Total-Size, Content-Type, Content-Length, Content-Range'),
        ]);
      }
      const length = actualEnd - actualStart + 1;
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      let bytes: ArrayBuffer;
      try {
        fs.lseek(file.fd, actualStart, fs.WhenceType.SEEK_SET);
        bytes = new ArrayBuffer(length);
        fs.readSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      return this.response(200, this.mimeOf(filePath), bytes, [
        this.header('X-Total-Size', String(total)),
        this.header('Content-Length', String(length)),
        this.header('Access-Control-Allow-Origin', '*'),
        this.header('Access-Control-Expose-Headers', 'X-Total-Size, Content-Type, Content-Length, Content-Range'),
      ]);
    } catch (error) {
      return this.response(404, 'text/plain', 'Not found', [
        this.header('Access-Control-Allow-Origin', '*'),
      ]);
    }
  }
}
