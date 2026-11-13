---
name: Veer OpenCode 参考原型
description: 本地合成 Web 交互规格；主对话与按需修改审阅，不是原生应用或 OpenCode 像素级复刻。
colors:
  ground: "#f2f2f0"
  surface: "#fff"
  quiet: "#f7f7f5"
  ink: "#242823"
  muted: "#61685e"
  line: "#d9ddd5"
  accent: "#236b42"
  selected: "#e4ece2"
  add: "#edf6ec"
  danger: "#a23434"
  glass: "#ffffffb8"
  dark-ground: "#1f221f"
  dark-surface: "#292d28"
  dark-quiet: "#242823"
  dark-ink: "#e9ece5"
  dark-muted: "#b0b7aa"
  dark-line: "#42493f"
  dark-accent: "#a0d3ae"
  dark-selected: "#344335"
  dark-add: "#303e31"
  dark-danger: "#f1b0aa"
  dark-glass: "#343b33b8"
typography:
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "24px"
    fontWeight: 600
  section:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "16px"
    fontWeight: 600
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "14px"
    lineHeight: 1.65
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "12px"
    lineHeight: 1.6
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "12px"
    lineHeight: 1.9
rounded:
  select: "6px"
  control: "8px"
  content: "12px"
  round: "20px"
spacing:
  s: "8px"
  m: "16px"
  l: "24px"
  xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.surface}"
    rounded: "{rounded.control}"
    padding: "8px 16px"
  button-glass:
    backgroundColor: "{colors.glass}"
    textColor: "{colors.ink}"
    rounded: "{rounded.round}"
    width: "40px"
    height: "40px"
  input:
    backgroundColor: "{colors.quiet}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "8px"
  composer:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.round}"
    padding: "16px"
  file-change:
    backgroundColor: "{colors.quiet}"
    rounded: "{rounded.control}"
    padding: "16px"
  navigation-current:
    backgroundColor: "{colors.selected}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    height: "40px"
---

# Design System: Veer OpenCode 参考原型

## Overview

**Creative North Star: "清晰、安静、可靠的工作台"**

沿用 Veer 的绿色标识、系统字体和等宽规则文本。用户已确认主对话＋可收起的右侧审阅，窄窗口以单区域切换；保留未导入首页。构图与参考已固定，采用 code-led 实现，不另造视觉身份。

本文件只描述 `prototype/opencode-review` 的 buildless HTML/CSS/JS 合成原型。`native/macos/PRODUCT.md` 是产品约束输入，不是本原型已实现的能力证明；没有真实文件读取、订阅下载、AI 请求、Key 存储、内核验证或代理控制。CSS 玻璃是网页近似，不是 macOS Liquid Glass。原生程序、原生 DESIGN/sidecar 及既有漂移均未改动。

**Key Characteristics:**

- 中性实底承载正文；玻璃仅用于操作层和导入入口。
- 摘要、处理记录、紧凑文件变更与完整审阅分层呈现。
- 候选、已确认到草稿与未应用代理始终明确区分。

参考依据是 OpenCode v2 源码提交 `4617210822bdbb31e5749751afbfb4584ccedac8`，应用包版本 2.0.26；详见 [固定参考记录](../../docs/OPENCODE_UI_REFERENCE_2026-10-14.md)。没有运行参考桌面应用或同提交真实截图比较，不声称像素级复刻。三项评分修复获准交付，不代表全面原生验证或 OpenCode 视觉一致性认证。

## Colors

前置 token 原样记录 `style.css`：无前缀为默认浅色，`dark-` 对应 `data-theme=dark` 对同名 CSS 变量的覆盖；不是两套可混搭色板。

### Primary

绿色 accent 用于品牌点、当前导航、确认、文本动作、插入光标与焦点；selected 是选择/悬停底色，add 只表示 Diff 新增。danger 用于持续错误文字，不用瞬时 Toast 替代错误。

### Neutral

ground 为工作区，surface 为对话/审阅/弹窗实底，quiet 为用户消息、文件条目、代码与选择器；ink/muted 区分正文和辅助说明，line 划分边界。glass 只供操作层的半透明底色。

## Typography

系统 sans-serif 是正文与控件的唯一字体栈；代码用系统等宽栈，不引入 OpenCode 字体。标题、分区、正文、辅助标签与代码的实际角色见 frontmatter。品牌另用 26px、650、−0.03em；三级标题为 14px/600，文件审阅身份为 13px，移动首页标题为 22px。助手文字行高 1.8，用户消息 1.65，输入 1.7；不以展示型大字压过工作内容。

## Layout

壳体高 100dvh、最小高 500px。侧栏固定 184px；工具栏 80px；内容区间隔及外边距 8px。时间线独立滚动，正文最大宽 760px，输入区独立停靠在下方。右侧审阅宽 46%、最小 420px、最大 680px，正文独立滚动，操作栏留在底部。

在 ≤1199px，打开审阅隐藏对话，审阅成为单区域；正文最大宽 850px，关闭后恢复对话阅读位置。在 ≤700px，侧栏隐藏，配置菜单进入顶部，工具栏高 72px、图标按钮 34px，正文收窄内边距。长文件名在身份栏截断（title 保留完整文件名）、在正文折行；长出口折行。Diff 保持一行一条、横向滚动，内部最大高 350px，不改成竖列。

## Elevation & Depth

内容通过实底色与 1px 边界分层，不使用浮起卡片阴影。导入圆形入口使用 `--shadow`（浅色 `0 8px 28px #26322612`；深色 `0 8px 28px #0003`）；操作玻璃用 16px backdrop blur。弹窗遮罩为 `#0004`。减少透明度偏好下移除模糊并改实底；forced-colors 下强化控件与新增行边界。没有 CSS 动画或过渡；时间线使用即时滚动。

## Shapes

控件与 Diff 使用 8px 圆角，对话/审阅与用户消息为 12px，输入容器、玻璃控件与弹窗为 20px。导入入口为圆形（桌面 144px，移动 128px），加号 56px。线性图标为本地内联 SVG，常规 20px；不依赖外部图标/字体库。

## Components

- **操作按钮与输入：**按钮默认透明，悬停 selected；主确认 accent 实底，悬停 brightness(.95)。禁用 opacity .45。常规 focus-visible 为 2px accent、偏移 3px；输入容器 focus-within 改 accent 边框。导入前输入、模式、导出与审阅禁用；处理中发送按钮变取消，输入/模式/导出禁用。
- **对话与审阅：**文件条目打开同一 turn 的候选。处理步骤披露保存在 turn；匹配范围披露按 turn ID＋服务名保留。打开/关闭窄屏审阅不丢输入或历史位置；上翻脱离跟随，“回到最新”显式恢复跟随。发送新指令进入最新位置；重新导入/重置会清空本轮状态并在已有对话时确认。
- **候选生命周期：**仅 pending 可确认；确认只写合成草稿，撤销只允许栈顶。新预览使旧 pending 失效，旧结果保留可读；放弃显示“已放弃此次候选，草稿未改变”。取消不会生成候选，失败在对话持续显示并可重试；Toast 4 秒后消失。
- **菜单与导出：**移动菜单可查看规则稿、策略组、AI 设置。文件/URL 入口都载入内置示例，不发送请求（CSP `connect-src 'none'`）。导出 `veer-demo-edited.yaml` 合成副本，含 rules 与 MATCH,DIRECT，不含真实配置。模式切换只是演示标签；不是真实解析器切换。

证据边界：本次实现会话记录了 5 项 Node 状态测试通过、JS 语法检查通过、HTTP 200；浏览器验证确认后 10 条/撤销后 0 条、错误、取消、移动菜单规则页及有效合成导出。最后三项修复证据为历史位置 120→120、逐 turn 披露保留、放弃文案准确。文档阶段只核对源码与现有截图，不新增浏览器/检测轮次。

已核对 [深色桌面](artifacts/desktop-dark.jpg)、[浅色桌面](artifacts/desktop-light.jpg)（1440×900）、[窄屏审阅](artifacts/narrow-review.jpg)、[历史恢复](artifacts/history-restored.jpg)、[匹配范围保留](artifacts/range-preserved.jpg)、[放弃状态](artifacts/discarded.jpg)（1080×760）及 [移动长文本](artifacts/mobile-long.jpg)（390×844）。截图证明对应合成状态的显示，不证明原生 OS 行为或真实网络能力。

## Do's and Don'ts

- Do 保持主对话＋按需审阅、窄窗口单区域与独立输入区。
- Do 将 pending、草稿确认、撤销、放弃与失效状态写清，保留阅读位置与逐 turn 披露。
- Do 保持两套主题语义一致、Diff 单行横向滚动和长文本可读。
- Don't 将网页玻璃、演示校验或地区标签写成原生材料、真实内核测试或网络可达证明。
- Don't 把合成导出写成完整真实配置导出，或复制 OpenCode 商标、字体、图标与源码。
- Don't 借本原型修改原生应用或刷新其既有设计文档/sidecar。
