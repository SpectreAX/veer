---
name: Veer macOS AI Editor
description: 清晰安静可靠的原生规则草稿工作台，实底内容与操作层 Liquid Glass
rounded:
  panel: "20pt"
  field: "12pt"
spacing:
  small: "8pt"
  section: "16pt"
  padding: "24pt"
  page-inset: "32pt"
components:
  workbench-panel:
    padding: "{spacing.padding}"
    rounded: "{rounded.panel}"
  review-panel:
    padding: "{spacing.section}"
    rounded: "{rounded.field}"
  file-entry:
    padding: "{spacing.section}"
    rounded: "{rounded.field}"
  rules-editor:
    height: "240pt"
  composer:
    height: "72pt"
    padding: "{spacing.section}"
    rounded: "{rounded.panel}"
  utility-action:
    size: "44pt"
  import-action:
    size: "144pt"
---

# Design System: Veer macOS AI Editor

## Overview

**Creative North Star: "清晰安静可靠的工作台"**

Veer 的 macOS 界面是原生 SwiftUI 工作台，不是网页包装。品牌承诺来自 `PRODUCT.md`：清晰、安静、可靠，保留绿色标识，沿用 macOS 原生控件与系统语义色。信息、编辑和审阅优先于装饰；不照搬 Android 卡片语言。

用户已确认 OpenCode 参考原型并要求「开始落地」。本次在既有视觉世界内刷新设计记录：保留导入画布，导入后以主对话承载指令、真实任务记录、出口摘要与紧凑文件条目，详细审阅按需打开。内容保持实底，Liquid Glass 只用于操作层与动作。原型是布局参考，不是运行证据；原生源码与本轮真实应用截图才是当前实现依据。

**Key Characteristics:**

- 原生控件、系统文字角色、语义色。
- 主对话与按需审阅，紧凑窗口一次呈现一个主要区域。
- 玻璃只在操作层，正文保持清晰稳定。
- 出口、验证限制与差异先于确认动作。
- 操作结果明确停留在规则草稿，不暗示代理已经生效。

当前记录日期为 2026-10-14，仅覆盖 `native/macos`。规范来源是 `Sources/VeerMac/EditorView.swift`、`ConversationTurnView.swift`、`ConversationReviewView.swift`、`WorkbenchStyle.swift`、`ConversationTurn.swift` 与 `EditorModel.swift`。实施合同见 `../../docs/MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md`。没有适用于 SwiftUI 的浏览器/CSS detector，本次未以网页检测代替原生审阅。

## Colors

颜色由 macOS 与 SwiftUI 解析，随系统环境变化；没有自建固定色板。原生表达记录在 sidecar 的 `extensions.native`，不伪装成 CSS 色值。

### Primary

- **Veer 绿色强调：**窗口级 `NSColor.systemGreen` tint 与侧栏品牌绿色标点；系统负责导航选择与控件状态，不强制自绘绿色背景。

### Neutral

- **主要内容：**`Color.primary` 与默认前景承担正文、出口与 Diff 文字。
- **次要说明：**`.secondary` 承担状态、数量、地区、验证限制与行号。
- **系统分隔：**`NSColor.separatorColor` 用于编辑器边框和面板细描边；`Divider` 保持系统样式。
- **窗口底色：**`NSColor.windowBackgroundColor`，也用于用户指令气泡。
- **内容实底：**`NSColor.controlBackgroundColor`，用于 composer、文件条目、审阅及减少透明度的操作层。
- **操作层材质：**macOS 26 的 `.glassEffect(.regular)`，旧系统回退 `.regularMaterial`；它是平台材质，不是固定颜色。

错误使用红色。Diff 行使用绿色/红色低强度底色（源码 `Color.green.opacity(0.08)` / `Color.red.opacity(0.08)`），正文不染色；`+` / `−`、行号和说明共同传达变化，不依赖颜色单一线索。

**The Semantic Color Rule.** 保留系统语义色与原生材质，不将其冻结为截图采样 hex，不生成未经平台定义的 tonal ramp。

## Typography

界面与正文使用 macOS 系统字体；规则和 Diff 使用系统等宽设计。系统文字角色不换算为猜测的像素字号、行高或字距。

### Hierarchy

- **Brand title：**`.title2.weight(.semibold)`，用于侧栏 Veer 标识。
- **Header / Section title：**`.headline`，用于文件标题、审阅、流量出口与 YAML Diff；文件标题中间截断，保留完整帮助文字。
- **Empty-state title：**导入提示使用 `.title2`，导入后指令空态使用 `.title`。
- **Body：**默认系统正文，承载指令、回复与出口；规则编辑器使用 `.body.monospaced()`。
- **Supporting text：**`.callout`，用于处理记录；完成摘要使用 medium，文件条目使用 semibold。
- **Metadata：**`.caption`，用于草稿状态、地区、隐私说明和验证限制；展开匹配范围使用 `.caption.monospaced()`。
- **Diff：**`.callout.monospaced()`，同排展示前后行号与规则文本。

唯一显式字号是导入 plus 图标（56pt、light），不是正文排版 scale。

**The Native Type Rule.** 延续系统文本角色和 monospaced 设计，不引入固定字体尺寸或网页字体栈作为原生实现规范。

## Layout

根布局使用 `.balanced` 的 `NavigationSplitView`：侧栏是「AI 工作台 / 规则稿 / 策略组 / AI 设置」，宽度约束为最小 160pt、理想 180pt、最大 210pt，底部常驻本机处理与不控制代理的说明。保留系统窗口控件与侧栏切换。已导入时顶部一行文件标题和草稿边界靠左，导入、撤销、导出、审阅开关、更多与外观动作靠右；规则检查与实底偏好收于更多菜单。URL 来源只显示「订阅配置.yaml」，不回显订阅地址。

未导入时中央圆形导入动作与「从一份配置开始」构成空态，底部实底 composer 只提示导入，没有可发送的指令。导入后主对话是可滚动的连续 turn，composer 固定在对话列底部；对话与 composer 最大宽度 900pt。规则稿、策略组、AI 设置仍是共享 model/session 的独立页面，不建立第二份草稿。

审阅切换依据是 `GeometryReader` 的 **detail 可用宽度**，不是整个窗口宽度或设备型号：达到 1000pt 时右侧并排，宽度为 detail 的 44%，限制在 420–540pt；不足时审阅覆盖主对话，形成单一可见区域。紧凑模式保持原对话 ScrollView 挂载和完整布局尺寸，使用 opacity、hit testing 与 accessibilityHidden 隐藏它，关闭后恢复原阅读位置，不把对话移除或压成零宽。审阅关闭只改呈现状态，保留选中 turn 和每轮匹配范围展开状态。

前置 token 的 pt 是 SwiftUI 逻辑点，不是 CSS 像素。节内使用 small，审阅/文件条目/composer 内边距与对话外边距使用 section，turn 间距和对话内容内边距使用 padding；标题区及独立页面沿用 page-inset。面板边框为 0.5pt；Diff 行号列各 36pt，Diff 视口 240pt，长规则保持单行并可横向滚动。composer token 是输入区高度，未导入提示使用同值作为最小高度，不是整个容器总高度。导入 sheet 宽 520pt。

窗口默认 1320 × 900pt，内容最小约束 1080 × 700pt；本轮实际最小窗口含系统标题区为 1080 × 738pt。原生截图为 Retina 像素：默认 2640 × 1800px，最小 2160 × 1476px，不能直接用截图像素定义布局。没有移动断点或自定义窗口动画。

## Elevation & Depth

内容层没有自定义阴影，以实底、间距、分隔线与轻描边分组。`OperationGlass` 用于工具动作、回到最新与底部反馈；减少透明度或用户实底偏好优先使用实底，其余在 macOS 26 使用 `.glassEffect(.regular)`，旧系统使用 `.regularMaterial`。主动作使用 `.glassProminent`，辅助动作使用 `.glass`，不满足条件则回退 bordered 样式。导入圆形动作使用原生 interactive glass。源码兼容 macOS 14，但旧 OS 与系统 Reduce Transparency 本轮未实测；没有自定义 motion token。

**The Native Surface Rule.** 内容面板保持实底可读，玻璃只属于操作层，不给正文、编辑器或 Diff 叠加透明材质和装饰性投影。

## Shapes

composer、通用实底面板和操作层使用 panel 圆角；用户指令气泡、文件条目与审阅使用 field 圆角。原生按钮、Picker、SecureField 与 `.roundedBorder` 字段保留平台轮廓，TextEditor 保留矩形边框；不把内容圆角强加给系统控件。导入动作保持圆形。

## Components

### Import / Composer

圆形加号或 ⌘O 打开文件/HTTPS URL 导入 sheet。下载或解析期间禁止重复操作，失败保留当前文档，sheet 内保留错误；URL 使用 SecureField，关闭或成功后清空。导入后 composer 展示模式、发送或取消、跟随控制及勿填密钥/订阅链接提示，生成使用 ⌘Return。外观和用户实底偏好保存在本机，文档、对话和撤销仍只在内存。

### Conversation / File Entry

每轮依次呈现用户指令、可展开的真实处理记录、回复、服务→出口摘要与紧凑文件条目。点击文件条目打开同一 turn 的审阅，不复制业务状态。实际成功流程只记录三步：准备本机草稿与指令、请求本地解析/AI 服务、收到差异与校验结果；不照搬原型四阶段演示，也不展示内部推理或假实时校验。运行时展示 elapsed 时间；失败和取消有重新生成入口。手动浏览历史暂停自动跟随，支持恢复跟随/回到最新，结果不能抢走历史阅读位置。

### Review / Diff

可关闭审阅读取同一 model 与选中 turn：文件与草稿状态、流量出口、未实测地区、每服务可展开匹配范围、单行 YAML Diff、警告和占位验证限制。Netflix / ChatGPT 汇总不跨出口或操作类型合并，也不删减底层规则。Diff 支持文本选择与复制，前后行号独立计数；复制内容保留 `+` / `−` 标记。底部固定操作区先说明草稿状态，再提供动作。

「确认修改」只确认到规则稿，不应用代理；仅当前有效 pending turn 可确认或放弃，输入/草稿变化令旧候选失效。旧结果保留只读，confirmed turn 的「撤销此修改」只在它对应快照栈顶时启用，不能跳过后续修改。范围展开状态按 turn 保存，确认、关闭和重开不重置它。

### Native Navigation / Fields / Feedback

侧栏使用系统 List 与 SF Symbols，选择、Hover、Focus、Pressed 由平台负责。策略组页面检查配置出口与声明地区；没有对应出口时不猜测。AI 设置的 SecureField 不回显已保存 Key，按 API 地址隔离，只恢复布尔状态。工具动作保留语义 label 与快捷键：撤销 ⇧⌘Z、导出 ⌘E；44pt 图标操作区不依赖 tooltip 才能识别。

非忙碌反馈是底部操作浮层，不预留布局高度：普通 4 秒、错误 8 秒，可关闭，重复消息重启计时，旧计时不能清除新消息。错误同时保留页面内说明；关闭 Toast 不代表错误已解决。运行过程由 turn 与取消入口呈现，不能声称做过真实长耗时 AI 或 VoiceOver 验证。

### Current Evidence — 2026-10-14

独立原生终审 disposition 为 **SHIP**：已映射默认/紧凑、浅深色、历史阅读、旧结果只读与披露持久性，没有待修机械 UI 问题。证据来自原生应用，不是浏览器：`artifacts/opencode-2026-10-14/landing-dark.png`、`desktop-dark.png`、`desktop-light.png`、`minimum-review.png`、`compact-review.png`、`history-before.png`、`history-after.png`、`old-record-readonly.png`（后七张同目录）。

本轮 29 项 Swift Tests 通过（VeerMac 15 / VeerEditor 14），Release 构建及 ad-hoc 签名验证通过；保留用户另一个未保存旧窗口。无节点/无密钥夹具实际验证导入、多服务生成、确认与撤销守卫；范围展开→确认→关闭/重开仍为 on；紧凑审阅关闭前后历史滚动值均为 0.4880382775119617。完整副本 `/tmp/veer-native-opencode-edited-20261014.yaml` 经 YAML 解析确认含当前 Netflix/ChatGPT→美国 10 条服务规则与 MATCH，非 rules 前缀逐字保留，未覆盖来源文件。

运行仍依赖单独启动的本机服务 `127.0.0.1:4317`。未调用真实 AI、未访问真实订阅、未读取钥匙串值；只有状态布尔值恢复。取消/失败有整合测试覆盖，但真实长耗时 AI、VoiceOver、macOS 14、系统 Reduce Transparency、真实网络可达性、公开签名/公证未实测。SHIP 是本次原生 UI 范围结论，不是公开分发或完整代理验证。

### Historical Evidence — superseded layouts

以下只保留此前验收事实，不作为当前布局规范。2026-10-11 Liquid Workbench 曾使用左右编辑/预览双栏，9 项测试与浅色 1120 × 860pt、导航保留候选、确认、规则稿同步和撤销通过；当时深色、精确最小窗口与实际导出尚未实测。截图：`artifacts/liquid-workbench.png`、`liquid-settings.png`、`liquid-review-fixed.png`。

同日后续 Codex 式导入画布替换旧双栏，浅深色空态、文件/公开 HTTPS YAML 导入、10 条规则预览确认和完整副本导出已验证；Node 43 项、Swift 20 项通过，1 项 fixture 跳过。详见 `../../docs/MACOS_PROTOTYPE_ADOPTION_2026-10-11.md` 与 `../../docs/MACOS_IMPORT_CONVERSATION_2026-10-11.md`。旧轮「未验证」与测试数量属于当时记录，不覆盖本轮结论。

## Do's and Don'ts

### Do:

- Do 复用系统语义色、文字角色、原生控件与现有 spacing scale。
- Do 先呈现明确出口、验证限制与 Diff，再允许确认规则草稿。
- Do 用文字、图标、行号和 Diff 前缀补足颜色的状态含义。
- Do 保留选中 turn、匹配范围展开与历史阅读位置，以同一 model 驱动审阅。
- Do 保留草稿范围、未实测地区、占位检查与内存存储的真实限制。

### Don't:

- Don't 从截图发明固定 hex、字体尺寸、阴影、tonal ramp 或动画 token。
- Don't 给规则、Diff 正文或内容面板加玻璃；Diff 保持 primary 正文与 + / − 前缀。
- Don't 把 Android 卡片或网页导航视觉直接移植到原生工作台。
- Don't 将「确认修改」写成连接代理、应用配置或真实出口已经验证。
- Don't 将原型演示阶段、源码兼容分支或 accessibility label 当成已完成的运行验证。
- Don't 在紧凑审阅时移除或压缩原对话，或让被隐藏的对话继续接受点击与辅助技术访问。
