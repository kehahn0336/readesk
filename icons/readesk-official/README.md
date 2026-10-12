# Readesk 应用图标资源包

Readesk —— Readest（readest.com，开源 EPUB/PDF 阅读器）的鸿蒙 PC 移植版。

## 设计说明

- **设计基因**：延续 Readest 官方图标（`project/readest/repo/data/icons/readest-book.png`）——
  翻开的书、暖黄书页、棕红封皮、橙色书签、右上翻页。
- **来源**：AI 生成位图插画（2026-10-10，三候选对比后韩老师选 A「官方基因版」），
  抠白底（四角 flood fill）后重排。
- **前景主体占比**：67.4%（对齐官方 DevEco 模板实测值），居中。
- **背景层**：暖白对角渐变 `#FFFFFF → #F6ECD9`，不透明。
- ⚠️ **svg/ 目录为空**：本图标源是位图插画（多色、有机形状），未做矢量化——
  这是家族 8 款中唯一没有矢量源的，重设计需从位图重新开始（或重新 AI 生成）。
- 草稿与候选对比图：`project/HarmonyAppIcons-drafts/Readesk/`（compare.png 有三版对比）。

## harmony-media/（原样拷进工程，两处都要放）

| 文件 | 规格 |
|---|---|
| foreground.png | 1024×1024，透明底（四角 alpha=0） |
| background.png | 1024×1024，不透明 |
| startIcon.png | 144×144，已套 22.5% 圆角（尺寸依据见下） |
| layered_image.json | 分层描述（键名 `layered-image`） |

接入（**AppScope 和 entry 各拷一份**）：

- `AppScope/resources/base/media/` ← `app.json5` 的 `"icon": "$media:layered_image"`
- `entry/src/main/resources/base/media/` ← `module.json5` 的 `"icon": "$media:layered_image"`、
  `"startWindowIcon": "$media:startIcon"`

### startIcon 为什么是 144（不是"像素太低"）

- 官方 DevEco 模板实测 = 144×144（四角 alpha=0）。
- 华为官网《应用冷启动时延优化》：**建议 startWindowIcon 不超过 256×256**，
  4096×4096 → 144×144 冷启动快 37.2ms（启动窗口图标要解码，越大越拖启动）。
- 本地对照：本机其它鸿蒙工程实测也在 144–216 之间，均远低于 256 上限。
- 想要更清晰的启动图标 → 用 `alt/startIcon-216.png`（22KB，比 144 的 12KB 大一点，
  仍在 256 上限内）。⚠️ 换尺寸时 **AppScope + entry 两处一起换**，且
  **深色变体必须与浅色同尺寸**（`startWindowIcon` 按原始尺寸居中显示、不随窗口缩放，
  两种模式尺寸不同 → logo 一大一小）。

## png/（合成图，**方形、不带圆角**）

1024 / 512 / 256 / 216 / 144 / 108 / 96 / 72 / 48 —— 全部四角 alpha=255。

🔴 **圆角归属**：素材一律**方形**，圆角由系统遮罩 / 上架平台自己裁，素材自带弧线是错的
（2026-10-10 韩老师指出后重导 —— 第一版给 png/ 套了 22.5% 圆角，已修正）。
唯一例外是 `startIcon.png`：官方 DevEco 模板实测它四角 alpha=0（自带圆角遮罩），照抄。

## 校验记录（2026-10-10）

全部通过：两 1024 尺寸、背景最小 alpha=255、前景四角 alpha=0、
前景 bbox 四角不落入圆角切除区、startIcon 四角 0/中心 255、
9 档 PNG 齐全且四角 alpha=255（方形，无自带圆角）。
