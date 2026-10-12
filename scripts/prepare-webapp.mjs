#!/usr/bin/env node
// Prepare a Next.js `out/` export for the HarmonyOS ArkWeb rawfile bundle.
//
// Usage:
//   node scripts/prepare-webapp.mjs [source-out]
//
// Default source: $READEST_REPO/apps/readest-app/out
// Destination:   <project>/entry/src/main/resources/rawfile/webapp
//
// `READEST_REPO` 指向上游 readest 仓库检出（默认见下），因为本项目与上游检出**不是**
// 注意别再假设"新项目在旧项目内部"—— 旧工程 repo/harmony/readest 已于 2026-10-07 删除，
// 本项目 readest-ohos/ 独立在工作区根。
//
// Post-processing:
//   - copies rawfile/readest-bridge.js into webapp/readest-bridge.js
//   - injects <script src="/readest-bridge.js"> as the first <head> child
//   - rewrites the Tauri rangefile origin to the same-origin appassets URL
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '..');
// 上游检出默认在「与本工程同级」的 repo/，可用 READEST_REPO 覆盖
const repo = process.env.READEST_REPO
  || path.join(path.resolve(project, '..'), 'repo');
const source = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(repo, 'apps/readest-app/out');
const dest = path.join(project, 'entry/src/main/resources/rawfile/webapp');
const bridgeSource = path.join(project, 'entry/src/main/resources/rawfile/readest-bridge.js');

const RANGE_FROM = Buffer.from('http://rangefile.localhost', 'utf8');
const RANGE_TO = Buffer.from('http://appassets.local/__rangefile__', 'utf8');
const BRIDGE_TAG = '<script src="/readest-bridge.js"></script>';

if (!fs.existsSync(path.join(source, 'index.html'))) {
  console.error(`[prepare-webapp] missing ${path.join(source, 'index.html')}`);
  process.exit(2);
}
if (!fs.existsSync(bridgeSource)) {
  console.error(`[prepare-webapp] missing ${bridgeSource}`);
  process.exit(2);
}

fs.rmSync(dest, { recursive: true, force: true });
fs.mkdirSync(dest, { recursive: true });
fs.cpSync(source, dest, { recursive: true });
fs.copyFileSync(bridgeSource, path.join(dest, 'readest-bridge.js'));

let files = 0;
let bytes = 0;
let htmlInjected = 0;
let rangeRewrites = 0;

const visit = (dir) => {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fp = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      visit(fp);
      continue;
    }
    // Type declarations are build-time-only; source maps are for Sentry/CI
    // symbolication and just inflate the HAP. Drop both from the rawfile tree.
    if (entry.name.endsWith('.d.ts') || entry.name.endsWith('.map')) {
      fs.rmSync(fp);
      continue;
    }

    files++;
    bytes += fs.statSync(fp).size;

    if (entry.name.endsWith('.html')) {
      const html = fs.readFileSync(fp, 'utf8');
      if (!html.includes(BRIDGE_TAG)) {
        const next = html.replace(/<head([^>]*)>/i, `<head$1>${BRIDGE_TAG}`);
        if (next !== html) {
          fs.writeFileSync(fp, next);
          htmlInjected++;
        }
      }
    }

    const buf = fs.readFileSync(fp);
    if (buf.includes(RANGE_FROM)) {
      fs.writeFileSync(fp, Buffer.from(buf.toString('latin1').split(RANGE_FROM.toString('latin1')).join(RANGE_TO.toString('latin1')), 'latin1'));
      rangeRewrites++;
    }
  }
};

visit(dest);
console.log(
  `[prepare-webapp] copied ${files} files, ${(bytes / 1024 / 1024).toFixed(1)} MiB -> ${dest}`,
);
console.log(`[prepare-webapp] bridge injected into ${htmlInjected} HTML files`);
console.log(`[prepare-webapp] rangefile rewritten in ${rangeRewrites} files`);
