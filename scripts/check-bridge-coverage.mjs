#!/usr/bin/env node
/**
 * 桥命令覆盖审计（分级判定）。
 *
 * 数据源：webapp 产物里 invoke("…") 的命令名 × ArkTS 桥里实现的命令名。
 *
 * 判级依据（来自一次真实漏实现的教训 —— read_dir）：
 *   (1) 非 plugin: 前缀的原生命令：这些是本应用自己的原生命令（上游 Rust 实现），
 *       漏一个就会让某条功能链断掉，且应用侧表现千奇百怪（read_dir 直接搞坏"从文件夹导入"）。
 *       → 未实现即失败（除非在 KNOWN_GAPS 里登记了影响）。
 *   (2) plugin:* 命令：多数由随包 JS 库提供，其中相当一部分只在桌面/iOS/Android 路径上
 *       被调用（plugin:menu|*、plugin:webview|*、plugin:haptics|* …）。
 *       静态无法判定"本平台是否真的会走到" → 只作信息输出；
 *       真正的判据是运行时：诊断日志里的 "unsupported bridge command: X"。
 *
 * 用法:
 *   node scripts/check-bridge-coverage.mjs           # 报告
 *   node scripts/check-bridge-coverage.mjs --strict  # 有未登记的非 plugin 缺口则 exit 1
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PROJ = join(dirname(fileURLToPath(import.meta.url)), '..');
const WEBAPP = 'entry/src/main/resources/rawfile/webapp/_next/static/chunks';
const SOURCES = [
  'entry/src/main/ets/bridge/ReadestBridge.ets',
  'entry/src/main/ets/bridge/legacy/LegacyBridge.ets',
];
/** 新域：命令进来时 plugin:<域>| 前缀已被剥掉，所以按"域 → 命令名"比对。 */
const DOMAINS = {
  'plugin:fs|': 'entry/src/main/ets/bridge/domains/FsDomain.ets',
  'plugin:path|': 'entry/src/main/ets/bridge/domains/PathDomain.ets',
  'plugin:window|': 'entry/src/main/ets/bridge/domains/WindowDomain.ets',
};
/** 由 shim（readest-bridge.js）在 JS 侧处理、根本不会到原生的前缀。 */
const SHIM_HANDLED = ['plugin:event|'];

/** 已知且有意不实现的命令。每条必须写清影响与归属，避免变成"静默忽略清单"。 */
const KNOWN_GAPS = {
  get_media_proxy_base: '有声书(Audiobookshelf)流媒体代理基址 —— M4 范围',
  get_comic_page_sizes: '漫画/CBZ 分页尺寸 —— M4 范围',
  spawn_fresh_browser: '外部浏览器打开链接 —— 未实现，M4 评估',
  show_lookup_popover: '桌面词典查词弹层 —— 未实现，M4 评估',
};

const abs = (rel) => join(PROJ, rel);
const read = (rel) => (existsSync(abs(rel)) ? readFileSync(abs(rel), 'utf8') : '');

function usedCommands() {
  const out = new Set();
  const dir = abs(WEBAPP);
  if (!existsSync(dir)) return out;
  const pat = /invoke\)?\(\s*"([A-Za-z0-9_|:.\-]+)"/g;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.js')) continue;
    for (const m of readFileSync(join(dir, f), 'utf8').matchAll(pat)) out.add(m[1]);
  }
  return out;
}

function implementedCommands() {
  const out = new Set();
  for (const rel of SOURCES) {
    const src = read(rel);
    for (const m of src.matchAll(/case '([A-Za-z0-9_|:.\-]+)'/g)) out.add(m[1]);
    for (const m of src.matchAll(/cmd === '([A-Za-z0-9_|:.\-]+)'/g)) out.add(m[1]);
  }
  for (const [prefix, rel] of Object.entries(DOMAINS)) {
    for (const m of read(rel).matchAll(/case '([A-Za-z0-9_]+)'/g)) out.add(prefix + m[1]);
  }
  return out;
}

const usedSet = usedCommands();
const implSet = implementedCommands();
if (usedSet.size === 0) {
  console.log('[bridge-coverage] 找不到 webapp 产物（先跑 prepare-webapp）');
  process.exit(0);
}

const gaps = [...usedSet].filter((c) => !implSet.has(c)).sort();
const plainGaps = gaps.filter((c) => !c.includes(':'));
const pluginGaps = gaps.filter((c) => c.includes(':') && !SHIM_HANDLED.some((p) => c.startsWith(p)));
const fatal = plainGaps.filter((c) => !(c in KNOWN_GAPS));

console.log(`[bridge-coverage] 产物引用 ${usedSet.size} 个命令；桥实现 ${implSet.size} 个`);
console.log(`\n(1) 非 plugin 原生命令缺口：${plainGaps.length}（其中未登记 ${fatal.length}）`);
for (const c of plainGaps) {
  const mark = c in KNOWN_GAPS ? '-' : 'x';
  const note = c in KNOWN_GAPS ? '  -> ' + KNOWN_GAPS[c] : '';
  console.log(`    ${mark} ${c}${note}`);
}
if (pluginGaps.length > 0) {
  const head = pluginGaps.slice(0, 12).join(', ');
  console.log(`\n(2) plugin:* 缺口（信息，多为随包库的桌面/iOS 路径）：${pluginGaps.length}`);
  console.log(`    ${head}${pluginGaps.length > 12 ? ' ...' : ''}`);
  console.log('    真正的判据在运行时：诊断日志里的 "unsupported bridge command: X"。');
}

const unused = [...implSet].filter((c) => !usedSet.has(c)).sort();
if (unused.length > 0) {
  console.log(`\n[bridge-coverage] 桥实现但产物未引用：${unused.length} 个`);
  console.log('    ⚠️ **勿据此删除**：产物里不少命令名是动态拼的（如 `plugin:${plugin}|${name}`），');
  console.log('    静态扫描必然漏判 —— 例如 plugin:app|version、plugin:fs|close 实际都在用。');
  console.log('    只作"这条可能已废弃"的线索，删除前须在产物里搜命令**片段**确认。');
  console.log(`    ${unused.slice(0, 12).join(', ')}${unused.length > 12 ? ' …' : ''}`);
}

if (fatal.length > 0) {
  console.log('\n发现未登记的非 plugin 缺口。漏实现就补进 LegacyBridge（或 domains/）；');
  console.log('确认要保留缺口就加进 KNOWN_GAPS 并写明影响。');
  if (process.argv.includes('--strict')) process.exit(1);
}
