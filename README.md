<img src="icons/readesk-official/png/icon-1024.png" width="96" alt="Readesk">

# Readesk

**Readest 的 HarmonyOS（鸿蒙）移植** —— 纯本地电子书阅读器，支持 `2in1` / 平板 / 手机。

| 项 | 值 |
| --- | --- |
| 包名 | `com.kehahn.readest` |
| 版本 | `0.1.0`（versionCode 10000） |
| 平台 | HarmonyOS，`deviceTypes = 2in1 / tablet / phone`，API 22（6.0.2） |
| 上游基线 | [readest/readest](https://github.com/readest/readest) @ `ac42ae5`（v0.12.8） |
| 许可 | **AGPL-3.0**（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)） |

> 本仓库是**移植工程**，不含上游源码。阅读器前端（webapp）由上游源码打上
> [`patches/0001-harmony-port-source-changes.patch`](patches/0001-harmony-port-source-changes.patch)
> 构建而来；本仓库提供 ArkTS 壳、鸿蒙桥、构建/验收脚本与图标资源。
>
> 开发过程中的设计与验证记录（逐条缺陷根因、真机证据、上架材料）**未随本仓库发布**。

---

## 1. 这是什么

上游 Readest 是 **Next.js + Tauri v2** 应用：前端是完整的 Web 应用，通过 Tauri 的
`invoke` 调用 Rust 侧的本地能力（文件、窗口、HTTP、TTS、剪贴板…）。

本移植复用这条边界：

```
┌─ ArkTS 壳（entry/）─────────────────────────────────────────────┐
│  EntryAbility        窗口创建 / 沉浸式 / 状态栏与避让区           │
│  pages/Index.ets     ArkWeb 宿主，加载 http://appassets.local/   │
│  bridge/             Tauri 兼容桥                                │
│    BridgeProtocol.ets  线上协议（信封形状、URI→路径规则）          │
│    ReadestBridge.ets   传输 + 路由（155 条命令）                  │
│    domains/            fs / path / window（按域重写 + 契约测试）   │
│    legacy/             其余域（单文件，逐步按域拆分）              │
│  rawfile/doctor.html   62 项自检页（一律经真实 JS 信封）           │
└────────────────────────────────────────────────────────────────┘
                      ▲  invoke / postMessage
┌─ webapp（从上游源码构建，产物不入库）────────────────────────────┐
│  静态导出 + 注入 readest-bridge.js + rangefile 源重写              │
└────────────────────────────────────────────────────────────────┘
```

三个关键设计：

1. **桥按 Tauri 的信封与命令名实现，前端几乎零改动** —— 上游前端大量调用
   `@tauri-apps/api`，我们让这些调用在鸿蒙上直接成立，而不是去改前端每一处调用点。
2. **单一数据源**：`readest-bridge.js` 只有一份，构建时注入到每个 HTML 的 `<head>`
   首子节点；`deploy-hap.sh` 会比对注入副本与源的 sha256，不一致就拒绝构建
   （历史事故：页面上跑的是另一个副本，改了却"没生效"）。
3. **验收必须走真实路径**：医生页的每一项都经真实 shim 打真实桥，禁止直调原生方法
   —— 否则验的是"我以为的路径"，不是应用真正走的那条。

## 2. 功能

### 已实现（真机验证）

- **阅读**：EPUB（含 IDPF/Adobe 混淆字体，需要 `crypto.subtle` 的 SHA-1）、PDF、
  MOBI/AZW3、漫画；分页/滚动、双栏、RTL、固定版式
- **导入**：单文件、**文件夹扫描**、拖拽、**内置浏览器下载 → 解包 → 入库**、
  **订阅源**（RSS 2.0 / Atom / JSON Feed / 网页自动发现）
- **阅读增强**：标注与笔记、书摘、主题与字体、布局、翻页动画、段落模式、速读（RSVP）
- **朗读**：TTS（Edge 在线音色）、**EPUB 3 Media Overlays 有声书**、锁屏媒体控件
- **在线（不依赖任何自建后端）**：OPDS 在线书库（可自建源）、书籍元数据查询
  （Google Books / Open Library 直连）
- **数据**：书库位置可自定义（可放在用户目录，卸载不丢）、备份 / 恢复
- **多形态**：2in1 沉浸式标题栏；平板"沉浸 ⇄ 菜单避让"；手机状态栏常显、内容始终在其下

### 有意关闭（上架形态）

统一由补丁新增的 `src/services/features.ts` 里的开关控制，默认全 `false`，
入口在界面上**完全隐藏**（而非灰掉）：

| 开关 | 关闭的能力 | 为什么 |
| --- | --- | --- |
| `CLOUD_ENABLED` | 登录 / 账号 / 云同步 / 分享到云 | 本移植**不携带任何后端**：官方后端在境外（数据出境合规），会员走 Stripe/Apple/Google IAP（华为市场要求华为 IAP） |
| `TRANSLATION_ENABLED` | 翻译 | 原有 provider 分别依赖官方后端、境外服务、或逆向网页接口，都不适合上架 |
| `UPDATER_ENABLED` | 应用内更新检查 | 上游更新源指向**别人的发布**，会提示安装上游 Readest，并在启动时静默请求上游地址 |

关停的审计方法（避免"改了一处、漏了另一处"）：不按文案找入口，而是列出所有含
sync/登录/账号/云字样的组件、再挑出**没有引用开关的文件**逐个确认可达性。
阅读器菜单里那条"登录后同步"就是这么找出来的 —— 它的文案是
`useCloudSyncStatus().label` **算出来的**，按字符串搜根本搜不到渲染处。

## 3. 构建

### 前置条件

- DevEco Studio（或 `devecocli` + `hvigor`）与 HarmonyOS SDK
- Node.js 20+，`pnpm`（用于上游 webapp 的依赖安装）
- 上游 Readest 检出放在**本工程同级**的 `repo/`

### 步骤

```bash
# 0) 签名：复制模板并填入自己的签名材料（真实文件不入库）
cp build-profile.template.json5 build-profile.json5
#    —— 填写说明见模板内注释；DevEco 自动签名会自动写好这段

# 1) 准备上游（与本工程同级）
git clone https://github.com/readest/readest ../repo
git -C ../repo checkout ac42ae5
git -C ../repo apply "$PWD/patches/0001-harmony-port-source-changes.patch"

# 2) 安装上游依赖
pnpm -C ../repo install

# 3) 构建 webapp 前端（产出 ../repo/apps/readest-app/out/）
node scripts/run-frontend-build.mjs

# 4) 准备 rawfile：out/ → entry/src/main/resources/rawfile/webapp，并注入桥
node scripts/prepare-webapp.mjs

# 5) 出 HAP（debug 签名，可侧载真机）
node "$RUNNER" "$PWD" build --product default --build-mode debug
```

脚本里的路径都可用环境变量覆盖，本机私有设置放 `.env.local`（已 gitignore，
模板见 [.env.local.example](.env.local.example)）：

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `READEST_REPO` | 上游检出路径 | `<工作区>/repo` |
| `READEST_WASI_BIN` | vendored pnpm 所在 `bin` | `<工作区>/research/bin` |
| `HDC` | hdc 可执行文件 | 由 `$DEVECO_SDK_HOME` 推导 |
| `DEPLOY_TARGET` | 装机目标（`序列号` 或 `ip:port`） | 留空由 hdc 选择 |
| `RUNNER` | 构建 runner（带显式 cwd 调 `devecocli`） | `$HOME/.workbuddy/tools/deveco-run.js` |

`scripts/deploy-hap.sh` 把「构建 → 校验 → 装机 → 启动」串成一条硬门槛流程：
构建失败、产物缺失、或两份 shim 的 sha256 不一致，都会**拒绝装机**，
避免"改了半小时、设备上跑的还是旧包"。

### 出上架包（AppGallery）

签名配置挂在 **product** 上而不是 buildMode —— 只加 `--build-mode release` 不会换签名：

```bash
node scripts/set-signing.mjs release      # 切到发布签名
node "$RUNNER" "$PWD" build --product default --build-mode release
# 产物：build/outputs/default/*-signed.app

node scripts/set-signing.mjs debug        # 自测前切回来！
```

两个容易踩的点：

- 发布 Profile（`app-distribution-type=app_gallery`）打出的包**无法侧载**，
  装机报 `9568322 not trusted app source` —— 这是正常的，它只能上传应用市场。
- 发布 Profile 必须包含应用申请的**全部 ACL 权限**，否则装不上。本工程申请了
  `READ_WRITE_DOCUMENTS_DIRECTORY`、`FILE_ACCESS_PERSIST`、`READ_WRITE_DOWNLOAD_DIRECTORY`
  三条，Profile 里要逐条对上。

另外：**release 构建会读 `entry/build-profile.json5` 里 release `buildOptionSet` 的混淆规则文件**，
该文件缺失会直接构建失败（`00304036 Not Found`）—— 本仓库已包含
[`entry/obfuscation-rules.txt`](entry/obfuscation-rules.txt)（当前 `enable=false`）。

## 4. 上游跟进

上游改动与我们改动的**唯一交界**是一个补丁文件：

```bash
git -C ../repo fetch && git -C ../repo checkout <新commit>
git -C ../repo apply "$PWD/patches/0001-harmony-port-source-changes.patch"   # 冲突即在此暴露
```

## 5. 验收与自检

| 手段 | 说明 |
| --- | --- |
| **医生页** `rawfile/doctor.html` | **62 项**自检，全部经真实 JS 信封打真实桥：fs 句柄读写、path 语义、窗口几何往返、http 流式读取、订阅源四格式矩阵、下载解包、导入搬运（含中文目录与百分号编码的 URI）、`crypto.subtle` 标准向量 |
| `scripts/ci.sh` | 静态 6 项：桥命令覆盖审计、shim 单一来源、webapp 新鲜度、脚本语法、中文文案完整性、交付目录卫生；加 `--device` 追加构建 + 装机 + 跑医生页 |
| `scripts/check-bridge-coverage.mjs` | 从 webapp 产物里抽出所有被引用的桥命令（278 条），与桥实现（155 条）对照，**非 plugin 缺口算失败** |

医生页可用 want 参数直接调起，便于脚本/CI 自动跑：

```bash
hdc shell "aa start -a EntryAbility -b com.kehahn.readest --ps page doctor"
```

## 6. 目录结构

```
readest-ohos/
├── entry/src/main/ets/         ArkTS 壳与桥（约 6.0k 行）
│   ├── entryability/           窗口创建、沉浸式、系统栏策略
│   ├── pages/                  ArkWeb 宿主 / 医生页宿主
│   └── bridge/                 协议 + 路由 + domains/ + legacy/
├── entry/src/main/resources/rawfile/
│   ├── doctor.html             62 项自检页
│   ├── readest-bridge.js       注入 webapp 的 shim（**单一来源**）
│   └── webapp/                 构建产物，不入库
├── scripts/                    构建·部署·审计·验收脚本
├── patches/                    对上游源码的全部改动 + vendor 补丁
└── icons/                      图标源与成品
```

## 7. 工程约定（来自真实事故）

1. **禁止区间删除**：删除必须精确锚点，且先打印待删行数；改动前先生成带时间戳的快照
2. **单一数据源**：`readest-bridge.js` 只存在一份，由构建脚本注入
3. **不允许假绿灯**：自检项要么真跑通、要么明确记为"跳过"，不许把失败写成通过
4. **每轮交付附证据**：医生页报告（真机、走真实 JS 路径）+ 构建日志
5. **移植树必须进版本控制**：上一次尝试没进 git，事故后无法回滚

## 8. 许可与署名

本工程是 [Readest](https://github.com/readest/readest) 的二次开发版本，依据
**GNU AGPL-3.0** 发布，许可证全文见 [LICENSE](LICENSE)。

对上游源码的全部改动集中在
[`patches/0001-harmony-port-source-changes.patch`](patches/0001-harmony-port-source-changes.patch)，
可完整复现；上游署名、修改清单、第三方组件许可以及**构建产物与源码的对应关系**
见 [NOTICE](NOTICE)。

> AGPL-3.0 要求向通过网络与本应用交互的用户提供**完整对应源代码**。
> 发布构建产物时，请确保 NOTICE 中 `<CONSOLE_PLACEHOLDER_SOURCE_URL>` 指向
> 真实可访问的源码地址（或本仓库的对应 tag）。
