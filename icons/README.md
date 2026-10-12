# 图标工作区

> ⚠️ **实际生效的图标是 `readesk-official/`**（用户交付的成品包，2026-10-10）。
> 下面这些 `readesk-*` 目录都是我出的**候选**，已被取代，保留仅作备选与历史。

## 家族风格

同一套图标家族统一为：**饱和渐变圆角方（radius 228/1024）+ 居中的白色单色图形**。

本目录下的候选都遵循该规则：底为渐变、图形为纯白（`fill` + `stroke` 44 让转角圆润）。

## 候选配色（2026-10-03）—— **已选定 `readesk-ink/`**

| 目录 | 渐变 | 对比度(32/16px) | 说明 |
| --- | --- | --- | --- |
| `readesk-indigo/` | `#4F46E5 → #7C3AED` | 2.90 / 2.66 | 蓝紫 |
| `readesk-rose/` | `#E11D48 → #FB7185` | 2.65 / 2.46 | 玫红 |
| `readesk-ink/` | `#0F172A → #334155` | **6.72 / 6.11** | **深色款，对比度最高、最能一眼区分 → 选定** |

> 早先还有一版"奶油纸底 + 深蓝书 + 橙书签"（`readesk/`，对比度 5.5–6.7），
> 因为**不在家族体系内**（浅底多色）被替换，留作参考。

每个目录：`master.svg`（含底，用于 Apple/Web/Windows/鸿蒙启动图）、
`foreground.svg`（仅标记，透明底，自适应前景）、`mono.svg`（单色层）、
`build/`（`icon_studio` 导出的 47 个成品 + `preview.png`）。

重新导出（改完 SVG 后）：
`icon_studio(svg=<master.svg>, foregroundSvg=<foreground.svg>, monoSvg=<mono.svg>, outDir=<build>, name="readesk", background=<主色>)`

## 装配映射（选定后照 `notes/app-icon.md` 第三节复制）
