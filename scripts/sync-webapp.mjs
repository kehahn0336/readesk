#!/usr/bin/env node
// Copy the Tauri static export into the HAP rawfile directory.
//
// Usage:
//   node readest-ohos/scripts/sync-webapp.mjs [path-to-out]
//
// Default source: <repo>/apps/readest-app/out
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '..');
const repo = path.resolve(project, '../..');
const source = process.argv[2] ? path.resolve(process.argv[2]) : path.join(repo, 'apps/readest-app/out');
const dest = path.join(project, 'entry/src/main/resources/rawfile/webapp');

if (!fs.existsSync(path.join(source, 'index.html'))) {
  console.error(`[sync-webapp] missing ${path.join(source, 'index.html')}`);
  console.error('[sync-webapp] build the Tauri frontend first, or pass an explicit out directory');
  process.exit(2);
}

fs.rmSync(dest, { recursive: true, force: true });
fs.mkdirSync(dest, { recursive: true });
fs.cpSync(source, dest, { recursive: true });

let files = 0;
let bytes = 0;
for (const entry of fs.readdirSync(dest, { recursive: true, withFileTypes: true })) {
  if (entry.isFile()) {
    files++;
    bytes += fs.statSync(path.join(entry.parentPath, entry.name)).size;
  }
}
console.log(`[sync-webapp] copied ${files} files, ${(bytes / 1024 / 1024).toFixed(1)} MiB -> ${dest}`);
