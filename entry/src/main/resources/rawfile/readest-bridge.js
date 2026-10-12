(function () {
  'use strict';
  try {
    Object.defineProperty(navigator, 'userAgent', {
      configurable: true,
      get: function () { return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'; },
    });
  } catch (e) {}

  // ArkWeb currently exposes crypto.getRandomValues but not randomUUID.
  // Readest's own file-import path uses crypto.randomUUID() when it copies
  // picker URIs into the app cache.
  try {
    if (window.crypto && typeof window.crypto.randomUUID !== 'function') {
      window.crypto.randomUUID = function () {
        var bytes = new Uint8Array(16);
        window.crypto.getRandomValues(bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var hex = '';
        for (var i = 0; i < bytes.length; i++) {
          var part = bytes[i].toString(16);
          hex += part.length === 1 ? '0' + part : part;
        }
        return (
          hex.slice(0, 8) + '-' +
          hex.slice(8, 12) + '-' +
          hex.slice(12, 16) + '-' +
          hex.slice(16, 20) + '-' +
          hex.slice(20)
        );
      };
    }
  } catch (e) {}

  // ArkWeb does not expose crypto.subtle. Edge TTS needs SHA-256 for its
  // Sec-MS-GEC token, so provide a small pure-JS digest implementation.
  try {
    if (window.crypto && !window.crypto.subtle) {
      window.crypto.subtle = {};
    }
    if (window.crypto && typeof window.crypto.subtle.digest !== 'function') {
      window.crypto.subtle.digest = function (algorithm, data) {
        return new Promise(function (resolve, reject) {
          try {
            // WebCrypto 允许传字符串或 {name}。统一成 'SHA1' / 'SHA256' 这种写法。
            var raw = typeof algorithm === 'string' ? algorithm
              : (algorithm && algorithm.name ? String(algorithm.name) : String(algorithm || ''));
            var name = raw.toUpperCase().replace(/-/g, '');
            var bytes;
            if (data instanceof ArrayBuffer) {
              bytes = new Uint8Array(data);
            } else if (ArrayBuffer.isView(data)) {
              bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            } else {
              bytes = new Uint8Array(data);
            }
            // 原来只认 SHA256，其它一律抛 "unsupported digest algorithm" ——
            // 带混淆字体的 EPUB 会因此导入/打开失败（真机实测：
            // "Failed to open the book file: unsupported digest algorithm: SHA-1"）。
            if (name === 'SHA1') return resolve(sha1Bytes(bytes).buffer);
            if (name === 'SHA256') return resolve(sha256Bytes(bytes).buffer);
            throw new Error('unsupported digest algorithm: ' + raw);
          } catch (e) {
            reject(e);
          }
        });
      };
    }
  } catch (e) {}

  /** SHA-1（FIPS 180-4）。用于 EPUB 的 IDPF/Adobe 字体反混淆（foliate-js epub.js）。 */
  function sha1Bytes(bytes) {
    var l = bytes.length;
    var bitLen = l * 8;
    var padLen = ((l + 1 + 8 + 63) & ~63);
    var msg = new Uint8Array(padLen);
    msg.set(bytes);
    msg[l] = 0x80;
    var high = Math.floor(bitLen / 0x100000000);
    var low = bitLen >>> 0;
    msg[padLen - 8] = (high >>> 24) & 0xff;
    msg[padLen - 7] = (high >>> 16) & 0xff;
    msg[padLen - 6] = (high >>> 8) & 0xff;
    msg[padLen - 5] = high & 0xff;
    msg[padLen - 4] = (low >>> 24) & 0xff;
    msg[padLen - 3] = (low >>> 16) & 0xff;
    msg[padLen - 2] = (low >>> 8) & 0xff;
    msg[padLen - 1] = low & 0xff;
    var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe,
        h3 = 0x10325476, h4 = 0xc3d2e1f0;
    var w = new Uint32Array(80);
    function rotl(x, n) { return (x << n) | (x >>> (32 - n)); }
    for (var i = 0; i < padLen; i += 64) {
      for (var j = 0; j < 16; j++) {
        w[j] = (msg[i + j * 4] << 24) | (msg[i + j * 4 + 1] << 16) |
               (msg[i + j * 4 + 2] << 8) | msg[i + j * 4 + 3];
      }
      for (var j2 = 16; j2 < 80; j2++) {
        w[j2] = rotl(w[j2 - 3] ^ w[j2 - 8] ^ w[j2 - 14] ^ w[j2 - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var t = 0; t < 80; t++) {
        var f, k;
        if (t < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
        else if (t < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
        else if (t < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else { f = b ^ c ^ d; k = 0xca62c1d6; }
        var temp = (rotl(a, 5) + f + e + k + w[t]) >>> 0;
        e = d; d = c; c = rotl(b, 30) >>> 0; b = a; a = temp;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
      h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
    }
    var out = new Uint8Array(20);
    var hs = [h0, h1, h2, h3, h4];
    for (var m = 0; m < 5; m++) {
      out[m * 4] = (hs[m] >>> 24) & 0xff;
      out[m * 4 + 1] = (hs[m] >>> 16) & 0xff;
      out[m * 4 + 2] = (hs[m] >>> 8) & 0xff;
      out[m * 4 + 3] = hs[m] & 0xff;
    }
    return out;
  }

  function sha256Bytes(bytes) {
    var K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
             0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var l = bytes.length;
    var withOne = l + 1;
    var bitLen = l * 8;
    var padLen = ((withOne + 8 + 63) & ~63);
    var msg = new Uint8Array(padLen);
    msg.set(bytes);
    msg[l] = 0x80;
    var high = Math.floor(bitLen / 0x100000000);
    var low = bitLen >>> 0;
    msg[padLen - 8] = (high >>> 24) & 0xff;
    msg[padLen - 7] = (high >>> 16) & 0xff;
    msg[padLen - 6] = (high >>> 8) & 0xff;
    msg[padLen - 5] = high & 0xff;
    msg[padLen - 4] = (low >>> 24) & 0xff;
    msg[padLen - 3] = (low >>> 16) & 0xff;
    msg[padLen - 2] = (low >>> 8) & 0xff;
    msg[padLen - 1] = low & 0xff;
    var w = new Uint32Array(64);
    function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
    for (var i = 0; i < padLen; i += 64) {
      for (var j = 0; j < 16; j++) {
        w[j] = (msg[i + j * 4] << 24) | (msg[i + j * 4 + 1] << 16) |
               (msg[i + j * 4 + 2] << 8) | msg[i + j * 4 + 3];
      }
      for (var j2 = 16; j2 < 64; j2++) {
        var s0 = rotr(w[j2 - 15], 7) ^ rotr(w[j2 - 15], 18) ^ (w[j2 - 15] >>> 3);
        var s1 = rotr(w[j2 - 2], 17) ^ rotr(w[j2 - 2], 19) ^ (w[j2 - 2] >>> 10);
        w[j2] = (w[j2 - 16] + s0 + w[j2 - 7] + s1) >>> 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3];
      var e = H[4], f = H[5], g = H[6], h = H[7];
      for (var t = 0; t < 64; t++) {
        var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var ch = (e & f) ^ (~e & g);
        var temp1 = (h + S1 + ch + K[t] + w[t]) >>> 0;
        var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var temp2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + temp1) >>> 0;
        d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0;
      H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0;
      H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    var out = new Uint8Array(32);
    for (var k = 0; k < 8; k++) {
      out[k * 4] = (H[k] >>> 24) & 0xff;
      out[k * 4 + 1] = (H[k] >>> 16) & 0xff;
      out[k * 4 + 2] = (H[k] >>> 8) & 0xff;
      out[k * 4 + 3] = H[k] & 0xff;
    }
    return out;
  }

  var callbacks = new Map();
  var nextCallbackId = 1;
  var eventListeners = new Map();
  var nextEventId = 1;
  var pluginChannels = new Map();
  var nextPluginEventIndex = new Map();
  var ASYNC_COMMANDS = {
    'plugin:dialog|open': true,
    'plugin:dialog|save': true,
    'plugin:http|fetch': true,
    'plugin:http|fetch_send': true,
    'plugin:http|fetch_read_body': true,
    'plugin:http|fetch_cancel': true,
    'plugin:http|fetch_cancel_body': true,
    'plugin:turso|load': true,
    'plugin:turso|execute': true,
    'plugin:turso|select': true,
    'plugin:turso|batch': true,
    'plugin:turso|close': true,
    'plugin:turso|get_config': true,
    'plugin:turso|ping': true,
    'plugin:turso|sync': true,
    'plugin:native-tts|init': true,
    'plugin:native-tts|get_all_voices': true,
    'plugin:native-tts|playout_control': true,
    'plugin:native-tts|playout_enqueue': true,
    'plugin:native-tts|playout_position': true,
    'plugin:native-tts|set_media_session_active': true,
    'plugin:native-tts|update_media_session_metadata': true,
    'plugin:native-tts|update_media_session_state': true,
    'plugin:native-bridge|copy_uri_to_path': true,
    'plugin:websocket|connect': true,
    'plugin:websocket|send': true,
    'clip_url': true,
    'open_web_browser': true,
    'set_web_browser_status': true,
    'fetch_web_browser_resource': true,
    'extract_web_browser_archive': true,
  };

  function transformCallback(callback, once) {
    var id = nextCallbackId++;
    callbacks.set(id, { callback: callback, once: !!once });
    return id;
  }

  function unregisterCallback(id) {
    callbacks.delete(id);
  }

  function runCallback(id, data) {
    var entry = callbacks.get(id);
    if (!entry) return;
    if (entry.once) callbacks.delete(id);
    if (entry.callback) entry.callback(data);
  }

  function u8ToBase64(u8) {
    var binary = '';
    for (var i = 0; i < u8.length; i++) binary += String.fromCharCode(u8[i]);
    return btoa(binary);
  }

  function base64ToU8(b64) {
    var binary = atob(b64);
    var u8 = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) u8[i] = binary.charCodeAt(i);
    return u8;
  }

  function encode(value) {
    if (value instanceof Uint8Array) {
      return { __readestUint8: u8ToBase64(value) };
    }
    if (value instanceof ArrayBuffer) {
      return { __readestUint8: u8ToBase64(new Uint8Array(value)) };
    }
    if (Array.isArray(value)) return value.map(encode);
    if (value && typeof value === 'object') {
      var toIpc = value.__TAURI_TO_IPC_KEY__;
      if (typeof toIpc === 'function') return toIpc.call(value);
      var out = {};
      for (var key in value) {
        if (Object.prototype.hasOwnProperty.call(value, key)) out[key] = encode(value[key]);
      }
      return out;
    }
    return value;
  }

  function decode(value) {
    if (!value || typeof value !== 'object') return value;
    // 二进制结果必须原样穿过：resolve() 与 invokeAsyncNative 的回调各会 decode
    // 一次，若这里把 Uint8Array 当普通对象遍历，它会退化成 {0:..,1:..} 而丢掉
    // byteLength/length。plugin:http|fetch_read_body 依赖"末字节=1 表示 EOF"，
    // 退化后 new Uint8Array(obj) 长度恒为 0、末字节恒为 undefined，读流会无限
    // 入队空块、永不 close —— 表现就是"从订阅源导入一直转圈"。
    if (value instanceof Uint8Array || value instanceof ArrayBuffer) return value;
    if (typeof value.__readestBytes === 'string') return base64ToU8(value.__readestBytes);
    if (Array.isArray(value)) return value.map(decode);
    var out = {};
    for (var key in value) {
      if (Object.prototype.hasOwnProperty.call(value, key)) out[key] = decode(value[key]);
    }
    return out;
  }

  function invokeNative(cmd, args) {
    if (!window.__readestHost || typeof window.__readestHost.invoke !== 'function') {
      return Promise.reject(new Error('Readest host bridge is not available'));
    }
    try {
      var raw = window.__readestHost.invoke(cmd, JSON.stringify(encode(args || {})));
      var env = JSON.parse(raw);
      if (env && env.ok === true) return Promise.resolve(decode(env.data));
      return Promise.reject(new Error((env && env.error) || ('bridge command failed: ' + cmd)));
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function handleEventCommand(cmd, args) {
    args = args || {};
    if (cmd === 'plugin:event|listen') {
      var eventId = nextEventId++;
      eventListeners.set(eventId, {
        event: args.event,
        target: args.target || { kind: 'Any' },
        handler: args.handler,
      });
      if (args.event === 'web-browser-download') {
        console.log('[bridge] event listen registered: ' + args.event);
      }
      return Promise.resolve(eventId);
    }
    if (cmd === 'plugin:event|unlisten') {
      eventListeners.delete(args.eventId);
      return Promise.resolve();
    }
    if (cmd === 'plugin:event|emit' || cmd === 'plugin:event|emit_to') {
      emitLocal(args.event, args.payload, args.target);
      return Promise.resolve();
    }
    return Promise.reject(new Error('unsupported event command: ' + cmd));
  }

  function emitLocal(event, payload, target) {
    var delivered = 0;
    eventListeners.forEach(function (entry) {
      if (entry.event !== event) return;
      // The stored handler is whatever `plugin:event|listen` received:
      // a numeric callback id from transformCallback, OR a Channel
      // serialized as the string "__CHANNEL__:<id>" / an {id} object.
      // runCallback needs the numeric id, so normalize first (previously
      // Channel-shaped handlers were silently dropped).
      var cbId = extractChannelId(entry.handler);
      if (cbId === undefined || cbId === null || !callbacks.get(cbId)) {
        if (event === 'web-browser-download') {
          console.log('[bridge] emitLocal no live callback for ' + event +
            ' handler=' + JSON.stringify(entry.handler));
        }
        return;
      }
      delivered++;
      runCallback(cbId, { event: event, id: cbId, payload: payload });
    });
    if (event === 'web-browser-download') {
      console.log('[bridge] emitLocal ' + event + ' listeners=' + eventListeners.size + ' delivered=' + delivered);
    }
  }

  function extractChannelId(handler) {
    if (typeof handler === 'string') {
      var match = /^__CHANNEL__:(\d+)$/.exec(handler);
      return match ? parseInt(match[1], 10) : handler;
    }
    if (handler && handler.id !== undefined) return handler.id;
    return handler;
  }

  function registerPluginListener(plugin, event, handler) {
    var channelId = extractChannelId(handler);
    if (channelId === undefined || channelId === null) {
      return Promise.reject(new Error('missing channel handler for ' + plugin + '|' + event));
    }
    var key = plugin + '|' + event;
    var channels = pluginChannels.get(key);
    if (!channels) {
      channels = new Map();
      pluginChannels.set(key, channels);
    }
    channels.set(channelId, channelId);
    nextPluginEventIndex.set(channelId, 0);
    return Promise.resolve(channelId);
  }

  function removePluginListener(plugin, event, channelId) {
    var key = plugin + '|' + event;
    var channels = pluginChannels.get(key);
    if (channels) channels.delete(channelId);
    nextPluginEventIndex.delete(channelId);
    return Promise.resolve();
  }

  function emitPlugin(plugin, event, payload) {
    var channels = pluginChannels.get(plugin + '|' + event);
    if (!channels) return;
    channels.forEach(function (channelId) {
      var index = nextPluginEventIndex.get(channelId) || 0;
      nextPluginEventIndex.set(channelId, index + 1);
      runCallback(channelId, { index: index, message: payload });
    });
  }

  function invokeAsyncNative(cmd, args) {
    return new Promise(function (resolve, reject) {
      var callbackId = transformCallback(function (data) {
        if (data && data.__readestError) {
          reject(new Error(String(data.__readestError)));
        } else {
          resolve(decode(data));
        }
      }, true);
      if (!window.__readestHost || typeof window.__readestHost.invokeAsync !== 'function') {
        unregisterCallback(callbackId);
        reject(new Error('Readest host async bridge is not available'));
        return;
      }
      try {
        window.__readestHost.invokeAsync(cmd, JSON.stringify(encode(args || {})), callbackId);
      } catch (error) {
        unregisterCallback(callbackId);
        reject(error);
      }
    });
  }

  function invoke(cmd, args, options) {
    if (cmd === 'plugin:event|listen' || cmd === 'plugin:event|unlisten' ||
        cmd === 'plugin:event|emit' || cmd === 'plugin:event|emit_to') {
      return handleEventCommand(cmd, args);
    }
    if (cmd.indexOf('|register_listener') >= 0) {
      var pluginName = cmd.slice('plugin:'.length, cmd.indexOf('|'));
      return registerPluginListener(pluginName, args && args.event, args && args.handler);
    }
    if (cmd.indexOf('|registerListener') >= 0) {
      var compatPluginName = cmd.slice('plugin:'.length, cmd.indexOf('|'));
      return registerPluginListener(compatPluginName, args && args.event, args && args.handler);
    }
    if (cmd.indexOf('|remove_listener') >= 0) {
      var removePluginName = cmd.slice('plugin:'.length, cmd.indexOf('|'));
      return removePluginListener(removePluginName, args && args.event, args && args.channelId);
    }
    if (cmd === 'plugin:websocket|connect') {
      var wsa = args || {};
      var om = wsa.onMessage;
      var wchId = -1;
      if (om && typeof om === 'object' && typeof om.id === 'number') wchId = om.id;
      else if (typeof om === 'number') wchId = om;
      var wh = {};
      if (wsa.config && Array.isArray(wsa.config.headers)) {
        for (var wi = 0; wi < wsa.config.headers.length; wi++) {
          var wp = wsa.config.headers[wi];
          if (wp && wp.length >= 2) wh[wp[0]] = wp[1];
        }
      }
      var wpayload = { url: wsa.url, onMessage: wchId, headers: wh };
      return invokeAsyncNative(cmd, wpayload).then(function (res) {
        return (res && typeof res === 'object' && 'id' in res) ? res.id : res;
      });
    }
    if (ASYNC_COMMANDS[cmd] === true) {
      return invokeAsyncNative(cmd, args);
    }
    // Tauri fs write commands pass the binary body as `args` and put the real
    // path/options in `options.headers`. Keep both halves for the native side.
    if (options && options.headers) {
      return invokeNative(cmd, { __readestArgs: args, __readestHeaders: options.headers });
    }
    return invokeNative(cmd, args);
  }

  function convertFileSrc(filePath) {
    return 'http://appassets.local/__rangefile__/?path=' + encodeURIComponent(filePath);
  }

  // 一次性迁移：早期构建把选择器返回的 URI 直接交给应用，而应用会把它存进
  // localStorage('readest:lastImportFolder')，并在「从文件夹导入」对话框里原样显示
  // —— 用户看到的就是 `file:///docs/…/%E6%B5%8B%E8%AF%95/…` 这种又长又像乱码的标识。
  // 桥修好之后新选择会回可读真实路径，但**存量旧值**也得迁一次，
  // 否则用户必须先"重新选一次文件夹"才能看到正常显示。
  try {
    var LAST_FOLDER_KEY = 'readest:lastImportFolder';
    var storedFolder = window.localStorage.getItem(LAST_FOLDER_KEY);
    if (storedFolder && storedFolder.indexOf('file:') === 0) {
      var readable = storedFolder.replace(/^file:\/+/, '').replace(/^docs\//, '');
      try { readable = decodeURIComponent(readable); } catch (e2) {}
      if (readable.charAt(0) !== '/') readable = '/' + readable;
      window.localStorage.setItem(LAST_FOLDER_KEY, readable);
      console.log('[bridge] migrated lastImportFolder -> ' + readable);
    }
  } catch (e) {}

  window.__READEST_BRIDGE__ = {
    resolve: function (id, data) { runCallback(id, decode(data)); },
    reject: function (id, error) {
      runCallback(id, { __readestError: String(error) });
    },
    emit: function (event, payload, target) { emitLocal(event, payload, target); },
    emitPlugin: function (plugin, event, payload) { emitPlugin(plugin, event, payload); },
    transformCallback: transformCallback,
    runCallback: runCallback,
  };

  window.__TAURI_INTERNALS__ = {
    metadata: {
      currentWindow: { label: 'main' },
      currentWebview: { label: 'main' },
      windows: [{ label: 'main' }],
      webviews: [{ label: 'main', windowLabel: 'main' }],
    },
    plugins: { path: { sep: '/', delimiter: ':' } },
    transformCallback: transformCallback,
    unregisterCallback: unregisterCallback,
    runCallback: runCallback,
    callbacks: callbacks,
    invoke: invoke,
    convertFileSrc: convertFileSrc,
  };

  window.__TAURI_OS_PLUGIN_INTERNALS__ = {
    platform: 'linux',
    os_type: 'linux',
    arch: 'aarch64',
    family: 'unix',
    exe_extension: '',
    eol: '\n',
    version: '',
  };

  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
    unregisterListener: function (event, eventId) { eventListeners.delete(eventId); },
  };




  window.isTauri = true;
  window.__READEST_HARMONY__ = true;
  // 设备形态（2in1 / tablet / phone）：供网页区分形态 —— 上游据此隐藏窗口三键
  // （hasWindowBar）与决定状态栏策略。走同步宿主调用，必须在应用 JS 之前就绪。
  try {
    var deviceFormEnv = JSON.parse(window.__readestHost.invoke('get_device_form', '{}'));
    if (deviceFormEnv && deviceFormEnv.ok === true) {
      window.__READEST_DEVICE_FORM__ = String(deviceFormEnv.data);
    }
  } catch (e) {
    console.warn('[bridge] device form unavailable:', e);
  }
  // 状态栏高度换算依赖 DPR（上游：statusBarHeight = 高度 / devicePixelRatio），
  // 记一行便于核对"菜单有没有被状态栏顶下去"。
  console.log('[bridge] device form=' + window.__READEST_DEVICE_FORM__ +
    ' dpr=' + window.devicePixelRatio +
    ' safeAreaTop=' + getComputedStyle(document.documentElement).getPropertyValue('--safe-area-inset-top'));
})();
