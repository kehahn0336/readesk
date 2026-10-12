#!/usr/bin/env bash
# 静态 CI：不依赖设备，随时可跑。设备侧回归用 --device。
#
# 用法:
#   bash scripts/ci.sh            # 静态检查（几秒）
#   bash scripts/ci.sh --device   # 静态 + 构建装机 + 医生页（需设备连着）
set -u
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ" || exit 1
FAIL=0

step() { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "✓ $1"; }
bad()  { echo "✗ $1"; FAIL=1; }

step "1/6 桥命令覆盖审计（非 plugin 缺口算失败）"
# notes/ 只放本机日志与证据（不入库）；公开仓库里没这个目录，兜底建出来
mkdir -p notes/evidence
if node scripts/check-bridge-coverage.mjs --strict >notes/.ci-bc.log 2>&1; then
  ok "$(grep -m1 "产物引用" notes/.ci-bc.log || echo '通过')"
else
  bad "有未登记的非 plugin 命令缺口："; grep -A6 "未登记" notes/.ci-bc.log | head -12
fi

step "2/6 shim 单一来源（两处必须逐字节一致）"
A=$(sha256sum entry/src/main/resources/rawfile/readest-bridge.js | cut -d' ' -f1)
B=$(sha256sum entry/src/main/resources/rawfile/webapp/readest-bridge.js 2>/dev/null | cut -d' ' -f1)
if [ -n "$B" ] && [ "$A" = "$B" ]; then ok "一致 ($A)"; else bad "不一致：rawfile=$A webapp=$B（跑 prepare-webapp.mjs）"; fi

step "3/6 webapp 新鲜度（产物须比源码新）"
W=$(find entry/src/main/resources/rawfile/webapp -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
S=$(find ../repo/apps/readest-app/src ../repo/apps/readest-app/public -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
if [ -n "$W" ] && [ -n "$S" ] && ! awk "BEGIN{exit !($S > $W)}"; then ok "产物不比源码旧"
else bad "产物比源码旧 —— 先跑 run-frontend-build.mjs && prepare-webapp.mjs"; fi

step "4/6 医生页与生成器语法"
for f in entry/src/main/resources/rawfile/doctor.html entry/src/main/resources/rawfile/readest-bridge.js; do
  node -e "
    const fs=require('fs'); const s=fs.readFileSync('$f','utf8');
    const m=s.match(/<script>([\s\S]*?)<\/script>/);
    new Function(m?m[1]:s);
  " && ok "$f 语法 OK" || bad "$f 语法错误"
done
python3 -c "import ast,sys; ast.parse(open('scripts/make-test-data.py').read())" && ok "make-test-data.py 语法 OK" || bad "make-test-data.py 语法错误"
python3 -c "import ast,sys; ast.parse(open('scripts/probe-feed.py').read())" && ok "probe-feed.py 语法 OK" || bad "probe-feed.py 语法错误"

step "4.5/6 中文文案完整性（本移植新增的文案必须有 zh 翻译）"
# 判据：拿 repo 的工作区与上游 ac42ae5 做 diff，收集**新增行**里的 _('...') 文案，
# 逐条确认 zh-CN 词表里有对应译文。比"写死几个文件名"可靠 —— 以后往任何文件里
# 加文案都会被覆盖到，不需要回来维护清单。
python3 - <<'PYEOF' || bad "有未翻译文案（中文设备上会显示英文）"
import json, re, os, subprocess, sys

base = '../repo/apps/readest-app'
upstream = 'ac42ae5'   # 本移植钉住的上游提交
zh = json.load(open(os.path.join(base, 'public/locales/zh-CN/translation.json'), encoding='utf-8'))

diff = subprocess.run(
    ['git', '-C', '../repo', 'diff', upstream, '--',
     'apps/readest-app/src', ':(exclude)apps/readest-app/src/__tests__'],
    capture_output=True, text=True).stdout
if not diff.strip():
    print('   与上游无差异？疑似取 diff 失败'); sys.exit(1)
added = '\n'.join(l[1:] for l in diff.splitlines()
                  if l.startswith('+') and not l.startswith('+++'))

def translated(key):
    if key in zh:
        return True
    # i18next 复数形式：词条 'X' 的译文可能是 'X_one' / 'X_other' / 'X_few' …
    # 中文只有 other 一类，所以 "Synced via {{count}} providers" 的译文本来就叫
    # "..._other" —— 只查原名会当成缺失（这里踩过）。
    prefix = key + '_'
    return any(k.startswith(prefix) for k in zh)

keys = sorted(set(re.findall(r"_\(\s*'([^']{2,})'", added)))
missing = [k for k in keys if not translated(k)]
print('   新增文案 %d 条，缺失 %d 条' % (len(keys), len(missing)))
for k in missing:
    print('   缺翻译: %s' % k[:70])
sys.exit(1 if missing else 0)
PYEOF

step "5/6 交付目录卫生（不该有旧包）"
OLD=$(ls dist/ 2>/dev/null | grep -E 'r[0-9]+-unsigned\.hap' | grep -v "$(ls -t dist/*.hap 2>/dev/null | head -1 | xargs -r basename)" || true)
[ -z "$OLD" ] && ok "只剩最新一个 HAP" || bad "存在多个 HAP：$OLD"

step "6/6 设备侧回归（可选）"
if [ "${1:-}" = "--device" ]; then
  bash scripts/deploy-hap.sh || bad "构建/装机失败"
  # 与 deploy-hap.sh 用同一套推导（本机设置见 .env.local）
  [ -f .env.local ] && . ./.env.local
  HDC="${HDC:-${DEVECO_SDK_HOME:-$HOME/deveco_tools/sdk}/default/openharmony/toolchains/hdc}"
  export HDC_SERVER_PORT="${HDC_SERVER_PORT:-8710}"
  $HDC shell "aa force-stop com.kehahn.readest" >/dev/null 2>&1; sleep 2
  $HDC shell "aa start -a EntryAbility -b com.kehahn.readest --ps page doctor" >/dev/null 2>&1
  sleep 38
  $HDC file recv "/data/app/el2/100/base/com.kehahn.readest/haps/entry/cache/doctor-report.json" notes/evidence/doctor-report-ci.json >/dev/null 2>&1
  python3 - <<'PY' || bad "医生页未全绿"
import json,sys
d=json.load(open('notes/evidence/doctor-report-ci.json'))
r=d['results']; ok=sum(1 for x in r if x['ok'])
print(f'  医生页 {ok}/{len(r)}')
bad=[x['name'] for x in r if not x['ok']]
for n in bad: print('   FAIL:', n)
sys.exit(0 if not bad else 1)
PY
else
  echo "  (跳过；加 --device 可跑构建+装机+医生页)"
fi

printf '\n=====================\n'
[ $FAIL -eq 0 ] && echo "CI 全部通过 ✓" || echo "CI 有失败项 ✗"
exit $FAIL
