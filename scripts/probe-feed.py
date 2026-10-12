#!/usr/bin/env python3
"""源探测：判断一个 URL 到底是不是订阅源、什么格式、有多少条。

用途：用户报"某个源导不进去"时，**先分清是源的问题还是应用的问题**。
预设与应用的判定保持一致（`src/services/rss/feedParser.ts::parseFeed`）：
  · 以 `{` 开头 → 按 JSON Feed 解析（要求顶层有 `items` 数组）
  · 否则按 XML 解析：`<feed>` → Atom；`<rss>`/`<rdf:RDF>`/`<channel>` → RSS
  · HTML 页面本身**不是源**，应用会走"从 HTML 里发现 feed 链接"那条路

关键判据（RSS 1.0/RDF 的坑）：**应用只扫 `<channel>` 内部的 `<item>`**，
而 RDF 的 `<item>` 是 `<channel>` 的**兄弟** → 于是"订阅成功但 0 条目"。
所以这里额外报告 `channel 内 item` 的数量。

用法:
  python3 scripts/probe-feed.py <url> [<url> ...]
  python3 scripts/probe-feed.py            # 跑内置矩阵
"""
import json
import re
import ssl
import sys
import urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

MATRIX = [
    ('RSS 2.0', 'https://sspai.com/feed'),
    ('Atom', 'https://blog.codingnow.com/atom.xml'),
    ('JSON Feed', 'https://www.jsonfeed.org/feed.json'),
    ('HTML（发现 feed 链接）', 'https://blog.codingnow.com/'),
    ('RSS 1.0 / RDF（已知限制）', 'https://slashdot.org/slashdot.rdf'),
    ('JSON 但非源（需登录）', 'https://e-c.coding.net/p/yicheng/d/YD/git/raw/master/dy.json'),
]


def fetch(url: str):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (readest-ohos feed probe)'})
    with urllib.request.urlopen(req, timeout=20, context=CTX) as r:
        return r.status, r.headers.get('Content-Type'), r.read()


def classify(url: str) -> str:
    try:
        status, ctype, body = fetch(url)
    except Exception as exc:                       # noqa: BLE001
        return '抓取失败: %s' % exc
    raw = body.decode('utf-8', 'replace')
    # 先剥掉 HTML 注释：Movable Type 之类会把 trackback 的 <rdf:RDF> 模板**注释**在页面里，
    # 不剥就会把 HTML 页误判成 RDF 源（应用用 XML DOM + querySelector，注释天然不匹配，
    # 所以应用不会犯这个错 —— 这里必须对齐，否则探测结果会误导排查）。
    sniff = re.sub(r'<!--.*?-->', '', raw, flags=re.S)
    trimmed = sniff.lstrip('\ufeff').strip()
    note = ''
    if trimmed.startswith('{'):
        try:
            doc = json.loads(trimmed)
        except Exception as exc:                    # noqa: BLE001
            return 'HTTP %s | application/json 但解析失败: %s' % (status, exc)
        if isinstance(doc, dict) and isinstance(doc.get('items'), list):
            kind, items = 'JSON Feed（应用支持）', len(doc['items'])
            note = 'title=%r' % doc.get('title')
        else:
            kind, items = 'JSON 但**不是** JSON Feed（应用会报 Unrecognized feed format）', 0
            keys = list(doc)[:4] if isinstance(doc, dict) else []
            note = '顶层键=%s' % keys
    elif re.match(r'^\s*(<\?xml[^>]*\?>\s*)?<(html|!doctype html)', trimmed, re.I):
        links = re.findall(r'<link[^>]+alternate[^>]*>', raw, re.I)
        kind = 'HTML 页面（本身不是源）'
        items = 0
        note = '可发现 %d 个 feed 链接: %s' % (
            len(links), '; '.join(re.findall(r'href="([^"]+)"', ' '.join(links))[:3]) or '无')
    elif re.search(r'<feed[\s>]', trimmed, re.I):
        kind, items = 'Atom（应用支持）', len(re.findall(r'<entry[\s>]', trimmed))
    elif re.search(r'<rdf:RDF', trimmed, re.I):
        chan = re.search(r'<channel[^>]*>.*?</channel>', trimmed, re.S | re.I)
        in_chan = len(re.findall(r'<item[\s>]', chan.group(0))) if chan else 0
        total = len(re.findall(r'<item[\s>]', trimmed))
        kind = 'RSS 1.0 / RDF'
        items = total
        note = 'channel 内 item=%d → 应用只会看到 %d 条（上游 parseRss 的已知限制）' % (in_chan, in_chan)
    elif re.search(r'<rss[\s>]', trimmed, re.I):
        kind, items = 'RSS 2.0（应用支持）', len(re.findall(r'<item[\s>]', trimmed))
    else:
        kind, items = '无法识别（应用会报 Unrecognized feed format）', 0
        note = '前 120 字节: %r' % trimmed[:120]
    return 'HTTP %s | %-46s items=%-4d %s' % (status, kind, items, note)


def main() -> None:
    urls = sys.argv[1:]
    if not urls:
        for label, url in MATRIX:
            print('%-26s %s' % (label, url))
            print('    %s' % classify(url))
            print()
        return
    for url in urls:
        print(url)
        print('    %s' % classify(url))


if __name__ == '__main__':
    main()
