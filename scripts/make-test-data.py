#!/usr/bin/env python3
"""生成 M3 验收用测试书（可复现，别再手搓）。

为什么需要它：M3 期间我们漏掉过整类缺陷，根因是**验收素材太简单**
（脚本生成的极简书没有字体，于是"带混淆字体的真实书导入失败"从未被触发）。
所以把素材代码化，并且**每份素材明确对应一类真实缺陷**：

  01-plain.epub            极简书，无字体 —— 基线
  02-obfuscated-font.epub  内嵌**IDPF 混淆字体** —— 触发 SHA-1 字体反混淆
                           （朋友实测报 unsupported digest algorithm: SHA-1）
  03-unicode-名.epub       非 ASCII 文件名/目录 —— 触发 URI 百分号编码
  04-not-a-book.epub       非 epub 内容改名 —— 负例，应报"损坏/不支持"而不是崩
  README.md                说明每份素材验证什么

用法:
    python3 scripts/make-test-data.py <output_dir>

IDPF 字体混淆规则（EPUB 3 OCF / epub.js deobfuscate）：
    key      = SHA-1( dc:identifier 去掉空白 )
    前 1040 字节逐字节与 key 循环异或
"""
import hashlib
import os
import random
import struct
import sys
import zipfile
import uuid
import zlib

FONT_SRC = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    '..', '..', 'extracted-webapp', 'vendor', 'pdfjs', 'standard_fonts',
    'LiberationSans-Regular.ttf',
)
IDPF_ALGORITHM = 'http://www.idpf.org/2008/embedding'

CONTAINER = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
'''

NAV = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body><nav epub:type="toc"><ol>
<li><a href="chapter1.xhtml">第一章</a></li>
<li><a href="chapter2.xhtml">第二章</a></li>
</ol></nav></body></html>
'''

ENC_XML = '''<?xml version="1.0" encoding="utf-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="{alg}"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/TestFont.ttf"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>
'''.format(alg=IDPF_ALGORITHM)


def make_png(width: int, height: int, seed: str) -> bytes:
    """生成一张随机像素的合法 PNG（不可压缩，用来把素材撑到真实体积）。

    为什么要它：文件夹导入对话框的 `DEFAULT_MIN_SIZE_KB = 20` —— 小于 20KB 的文件
    会被**默认过滤掉**。我们第一版素材只有 ~2KB，于是"只导入了 1 本"看起来像 bug。
    真实电子书都远大于 20KB，所以素材也应该如此。
    """
    rnd = random.Random(seed)
    raw = bytearray()
    for _ in range(height):
        raw.append(0)  # filter type 0
        raw.extend(rnd.getrandbits(8) for _ in range(width * 3))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(bytes(raw), 1)) + chunk(b'IEND', b''))


def obfuscate_idpf(data: bytes, identifier: str) -> bytes:
    """按 IDPF 规则混淆前 1040 字节（key = SHA-1(identifier)）。"""
    key = hashlib.sha1(identifier.encode('utf-8')).digest()
    buf = bytearray(data)
    n = min(1040, len(buf))
    for i in range(n):
        buf[i] ^= key[i % len(key)]
    return bytes(buf)


def chapter(title: str, body: str, font_family: str = '') -> str:
    style = ''
    if font_family:
        style = '<style>body{font-family:"%s",serif;}</style>' % font_family
    return '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title>%s</head>
<body><h1>%s</h1>%s</body></html>''' % (title, style, title, body)


def build(path: str, title: str, identifier: str, *, font: bytes = None,
          obfuscate: bool = False, garbage: bool = False) -> None:
    if garbage:
        # 也要超过"文件夹导入"的 20KB 默认阈值，否则会被静默过滤掉，
        # 就测不到"损坏文件应报错而不是崩溃"这条负例。
        with open(path, 'wb') as fh:
            fh.write(b'this is definitely not an epub file\n' * 1400)
        return

    manifest = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                '<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>',
                '<item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>',
                '<item id="cover-img" href="images/cover.png" media-type="image/png"/>']
    font_family = ''
    if font is not None:
        manifest.append('<item id="font" href="fonts/TestFont.ttf" media-type="font/ttf"/>')
        manifest.append('<item id="css" href="style.css" media-type="text/css"/>')
        font_family = 'TestFont'

    opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:title>%s</dc:title>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-09-30T02:00:00Z</meta>
  </metadata>
  <manifest>%s</manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''' % (identifier, title, ''.join(manifest))

    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        # mimetype 必须是第一个条目且不压缩
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', CONTAINER)
        if obfuscate:
            z.writestr('META-INF/encryption.xml', ENC_XML)
        z.writestr('OEBPS/content.opf', opf)
        z.writestr('OEBPS/nav.xhtml', NAV)
        z.writestr('OEBPS/chapter1.xhtml',
                   chapter('第一章', '<p>这份素材用于 M3 验收。identifier = %s</p>' % identifier, font_family))
        z.writestr('OEBPS/chapter2.xhtml',
                   chapter('第二章',
                           '<p>如果你能读到这一页，说明这本书被正常解析了。</p>'
                           '<p><img src="images/cover.png" alt="cover"/></p>', font_family))
        z.writestr('OEBPS/images/cover.png', make_png(240, 240, identifier))
        if font is not None:
            z.writestr('OEBPS/style.css',
                       '@font-face{font-family:"TestFont";src:url("fonts/TestFont.ttf");}\nbody{font-family:"TestFont",serif;}\n')
            payload = obfuscate_idpf(font, identifier) if obfuscate else font
            z.writestr('OEBPS/fonts/TestFont.ttf', payload)


def build_pdf(path: str, title: str, size_bytes: int = 40000) -> None:
    """极简但**合法**的 PDF（带 xref 表），用注释把体积撑过 20KB 阈值。

    为什么优先做它：文件夹导入对话框的默认勾选是 ['epub', 'pdf']，
    而桥里 parse_pdf_metadata / render_pdf_cover 是"返回 null 让 JS 兜底"的改动 ——
    这条路径必须真机验证（PDF 的 tryNativeParsePdf 用 Promise.allSettled，
    两个都 rejected 会 throw，从而让整个 PDF 导入失败）。
    """
    ascii_title = title.encode('ascii', 'ignore').decode('ascii') or 'Readest Test PDF'
    content = ('BT /F1 18 Tf 40 160 Td (' + ascii_title + ') Tj ET\n').encode('ascii')
    pad_len = max(0, size_bytes - len(content) - 8)
    content += b'%' + (b'x' * pad_len)

    objs = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R '
        b'/Resources << /Font << /F1 5 0 R >> >> >>',
        b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'\nendstream',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ]
    out = bytearray(b'%PDF-1.4\n')
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += str(i).encode() + b' 0 obj\n' + body + b'\nendobj\n'
    xref_pos = len(out)
    out += b'xref\n0 ' + str(len(objs) + 1).encode() + b'\n0000000000 65535 f \n'
    for off in offsets:
        out += ('%010d 00000 n \n' % off).encode()
    out += (b'trailer\n<< /Size ' + str(len(objs) + 1).encode() + b' /Root 1 0 R >>\n'
            b'startxref\n' + str(xref_pos).encode() + b'\n%%EOF\n')
    with open(path, 'wb') as fh:
        fh.write(bytes(out))


def build_fb2(path: str, title: str, pad_bytes: int = 30000) -> None:
    filler = ('<p>这是一段用于撑体积的填充文本。Filler paragraph for size. </p>'
              * (pad_bytes // 60 + 1))
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">\n'
           '<description><title-info><book-title>%s</book-title>'
           '<lang>zh-CN</lang></title-info></description>\n'
           '<body><section><title><p>第一章</p></title>%s</section></body>\n'
           '</FictionBook>\n') % (title, filler)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(xml)


def build_text(path: str, title: str, markdown: bool = False, pad_bytes: int = 30000) -> None:
    lines = [('# ' + title) if markdown else title, '']
    block = ('这是一段用于撑体积的填充文本。' if not markdown
             else '这是一段**填充**文本，用于撑体积。')
    while sum(len(x.encode('utf-8')) for x in lines) < pad_bytes:
        lines.append(block)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines) + '\n')


def build_html(path: str, title: str, pad_bytes: int = 30000) -> None:
    filler = ('<p>这是一段用于撑体积的填充文本。Filler paragraph.</p>'
              * (pad_bytes // 55 + 1))
    html = ('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<title>%s</title></head><body><h1>%s</h1>%s</body></html>\n') % (title, title, filler)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(html)


README = '''# M3 验收测试书（自动生成）

> 由 `readest-ohos/scripts/make-test-data.py` 生成 —— 改素材请改脚本，不要手改这里。

| 文件 | 验证什么 | 预期 |
| --- | --- | --- |
| `01-plain.epub` | 基线：极简书、无字体 | 正常导入并打开 |
| `02-obfuscated-font.epub` | **IDPF 混淆字体** → SHA-1 反混淆 | 正常导入并打开；旧版会报 `unsupported digest algorithm: SHA-1` |
| `03-unicode-名.epub` | 非 ASCII 文件名 → URI 百分号编码 | 正常导入（旧版 `copy_file` 会 ENOENT） |
| `04-not-a-book.epub` | 负例：不是 epub | 报"损坏/不支持"，**不应崩溃**，也不应中断同批其它书 |
| `05-sample.pdf` | PDF（对话框**默认勾选**） | 正常导入；旧版因两个原生命令都 rejected 而**必失败** |
| `06-sample.fb2` | FB2（需勾选 FB2） | 正常导入 |
| `07-sample.txt` / `08-sample.md` | 纯文本 / Markdown（需勾选 TXT/MD） | 正常导入 |
| `09-sample.html` | HTML（需勾选 HTML） | 正常导入 |

> 未覆盖：`mobi/azw/azw3`（构造合法 MOBI 成本高，未做）、`zip/cbz`（那条路径属于
> "内置浏览器下载后解包"，已由医生页的解包用例覆盖）。

## 建议怎么用

1. **单文件导入**：逐个选上面 4 个，前 3 个应成功、第 4 个应给出可读的错误提示。
2. **从文件夹导入**：直接选**本目录**（`测试/readest`）—— 目录名与文件名都含非 ASCII
   与中文，正好覆盖 URI 编码这条路径；应能列出并逐本入库。
3. 若某本失败，把应用缓存里的诊断日志发回：
   `bridge-diag-*.log`（路径见交付说明第 5 节）。

## 已知的三条前置条件

- **首次导入会弹权限申请（文档/下载），必须点「允许」** —— 这是系统 `user_grant` 权限。
- 桌面上的书建议先移到「文档」再导入：桌面目录权限等级是 `system_basic`，普通应用声明它会导致安装失败。
- **「从文件夹导入」默认只导入 ≥ 20 KB 的文件**（对话框里的"最小文件大小"，默认 20）。
  本目录的素材都做过体积处理（每本都内嵌一张 240×240 的封面 PNG），所以默认设置下全部可导入；
  若你手动把阈值调大，小书会被静默跳过 —— 那不是失败，是被过滤。
'''


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)

    font = None
    if os.path.exists(FONT_SRC):
        with open(FONT_SRC, 'rb') as fh:
            font = fh.read()
    else:
        print('warn: 找不到字体源 %s，02 将不含字体' % FONT_SRC)

    plain_id = 'urn:uuid:' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'readest-m3-plain'))
    font_id = 'urn:uuid:' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'readest-m3-obfuscated'))
    uni_id = 'urn:uuid:' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'readest-m3-unicode'))

    build(os.path.join(out, '01-plain.epub'), 'M3 测试：基线（无字体）', plain_id)
    build(os.path.join(out, '02-obfuscated-font.epub'), 'M3 测试：混淆字体',
          font_id, font=font, obfuscate=True)
    build(os.path.join(out, '03-unicode-名.epub'), 'M3 测试：非 ASCII 文件名', uni_id)
    build(os.path.join(out, '04-not-a-book.epub'), '坏的', 'ignored', garbage=True)
    # 其余格式：pdf 在对话框里**默认勾选**（与 epub 并列），优先验证；
    # fb2/txt/md/html 需要用户勾选对应格式才会进。
    build_pdf(os.path.join(out, '05-sample.pdf'), 'Readest Test PDF')
    build_fb2(os.path.join(out, '06-sample.fb2'), 'M3 测试：FB2')
    build_text(os.path.join(out, '07-sample.txt'), 'M3 测试：纯文本')
    build_text(os.path.join(out, '08-sample.md'), 'M3 测试：Markdown', markdown=True)
    build_html(os.path.join(out, '09-sample.html'), 'M3 测试：HTML')

    with open(os.path.join(out, 'README.md'), 'w', encoding='utf-8') as fh:
        fh.write(README)

    for name in sorted(os.listdir(out)):
        p = os.path.join(out, name)
        if os.path.isfile(p):
            print('  %-28s %8d B' % (name, os.path.getsize(p)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
