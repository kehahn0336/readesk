#!/usr/bin/env node
// 从源码构建 Readest webapp（HarmonyOS/ArkWeb 目标）。
//
// 关键点（沿用旧项目已验证的配方）：
//   - PATH 前置 research/bin：使用 vendored 的 pnpm（11.x）
//   - NAPI_RS_FORCE_WASI=true：让 napi-rs 依赖走 WASI 预编译产物（无 OHOS native 包）
//   - dotenv -e .env.tauri：NEXT_PUBLIC_APP_PLATFORM=tauri（桥方案成立的前提）
//   - --webpack：turbopack 在本工具链下不可用
// 产出：repo/apps/readest-app/out/  交给 prepare-webapp.mjs
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '..');
// 上游 Readest 检出与 vendored pnpm 都在本工程**之外**的工作区里。
// 默认按「与本工程同级」推导，可用环境变量覆盖：
//   READEST_REPO     上游检出路径（默认 <工作区>/repo）
//   READEST_WASI_BIN vendored pnpm 所在 bin（默认 <工作区>/research/bin）
const workspace = path.resolve(project, '..');
const repo = process.env.READEST_REPO || path.join(workspace, 'repo');
const app = path.join(repo, 'apps/readest-app');
const wasiBin = process.env.READEST_WASI_BIN || path.join(workspace, 'research', 'bin');
const log = path.join(project, 'notes', 'frontend-build.log');
const exitFile = path.join(project, 'notes', 'frontend-build.exit');

for (const p of [path.join(app, '.next'), path.join(app, 'out')]) {
  fs.rmSync(p, { recursive: true, force: true });
}

const out = fs.openSync(log, 'w');
const env = { ...process.env };
env.PATH = wasiBin + ':' + env.PATH;
env.NAPI_RS_FORCE_WASI = 'true';
env.NEXT_TELEMETRY_DISABLED = '1';
env.NODE_OPTIONS = '--max-old-space-size=10240';

console.log(`[build] cwd=${app}`);
console.log(`[build] log=${log}`);

const child = spawn('pnpm', ['exec', 'dotenv', '-e', '.env.tauri', '--', 'next', 'build', '--webpack'], {
  cwd: app,
  env,
  stdio: ['ignore', out, out],
});
child.on('exit', (code, signal) => {
  fs.writeFileSync(exitFile, JSON.stringify({ code, signal, at: new Date().toISOString() }));
  fs.closeSync(out);
  console.log(`[build] exit code=${code} signal=${signal}`);
});
child.on('error', (err) => {
  fs.writeFileSync(exitFile, JSON.stringify({ error: String(err), at: new Date().toISOString() }));
  console.log(`[build] spawn error: ${String(err)}`);
});
