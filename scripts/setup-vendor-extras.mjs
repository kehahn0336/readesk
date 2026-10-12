#!/usr/bin/env node
// 上游 `pnpm setup-vendors` 生成的 public/vendor 里缺少 pdfjs 的**同名声明**：
// 模块说明符是 `@pdfjs/pdf.min.mjs`，声明却是 `pdf.d.mts`，TypeScript 无法把它
// 关联到 `pdf.min.mjs`，只能从 JS 推断类型 → 构建期类型检查报错。
// 本脚本补一个 28 字节的同名声明，使类型走真实 pdfjs 类型。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '..');
const repo = process.env.READEST_REPO || path.join(path.resolve(project, '..'), 'repo');
const vendorDir = path.join(repo, 'apps/readest-app/public/vendor/pdfjs');
const src = path.join(project, 'patches/vendor/pdfjs/pdf.min.d.mts');

if (!fs.existsSync(vendorDir)) {
  console.error(`[vendor-extras] 缺少 vendor 目录：${vendorDir}（先运行 pnpm setup-vendors）`);
  process.exit(2);
}
fs.copyFileSync(src, path.join(vendorDir, 'pdf.min.d.mts'));
console.log(`[vendor-extras] installed ${path.join(vendorDir, 'pdf.min.d.mts')}`);
