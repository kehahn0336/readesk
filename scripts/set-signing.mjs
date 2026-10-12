#!/usr/bin/env node
/**
 * Readesk · 切签：debug ↔ release。
 *
 * 背景：HarmonyOS 的签名配置挂在 **product** 上（不是 buildMode），
 * 而两种签名的用途互斥：
 *   · debug   —— 可侧载真机，日常开发/自测用；
 *   · release —— p7b 是 app_gallery 类型，**只能上传应用市场，侧载报
 *                9568322 not trusted app source**。
 * 所以「出上架包」和「装机自测」必须显式切换，不能靠 buildMode 区分。
 *
 * 用法：
 *   node scripts/set-signing.mjs           打印当前用的是哪套
 *   node scripts/set-signing.mjs debug     切到调试签名（真机验证）
 *   node scripts/set-signing.mjs release   切到发布签名（出 .app 上架）
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const NAME = { debug: 'default', release: 'release' };
const LABEL = {
  default: '调试签名（可侧载真机）',
  release: '发布签名（app_gallery，只能上传应用市场，无法侧载）',
};

// 本脚本位于 scripts/，所以 root = 工程根
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = path.join(root, 'build-profile.json5');
const src = readFileSync(file, 'utf8');

const RE = /("signingConfig"\s*:\s*")([^"]+)(")/;
const m = src.match(RE);
if (!m) {
  console.error('未在 build-profile.json5 找到 signingConfig');
  process.exit(1);
}

const declared = [...src.matchAll(/"name":\s*"([^"]+)",\s*\n\s*"type":\s*"HarmonyOS"/g)].map(
  (x) => x[1],
);
const current = m[2];
const wantRaw = process.argv[2];

if (!wantRaw) {
  console.log(`当前签名配置：${current} — ${LABEL[current] ?? '未知'}`);
  console.log(`配置里已声明：${declared.join(', ')}`);
  process.exit(0);
}
if (!Object.hasOwn(NAME, wantRaw)) {
  console.error(`未知参数 "${wantRaw}"，只接受 debug 或 release。`);
  process.exit(1);
}
const want = NAME[wantRaw];
if (!declared.includes(want)) {
  console.error(
    `配置里没有名为 "${want}" 的 signingConfig（已有：${declared.join(', ')}），拒绝写入。`,
  );
  process.exit(1);
}
if (current === want) {
  console.log(`已经是 ${wantRaw}（${want}），无需切换。`);
  process.exit(0);
}
writeFileSync(file, src.replace(RE, `$1${want}$3`), 'utf8');
console.log(`签名配置 ${current} -> ${want}（${LABEL[want]}）`);
if (want === 'release') {
  console.log('提示：发布签名的包装机必报 9568322，出完 .app 记得切回 debug 再自测。');
}
