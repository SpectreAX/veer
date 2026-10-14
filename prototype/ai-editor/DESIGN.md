---
name: Veer AI Editor
description: 继承 Veer 绿色 Material 语气的可检查配置编辑工作台。
colors:
  bg: "#fafdf5"
  surface: "#fff"
  subtle: "#eef1e9"
  ink: "#1a1c17"
  muted: "#45483f"
  border: "#c5c8bd"
  primary: "#426900"
  on-primary: "#fff"
  primary-soft: "#dceac5"
  error: "#ba1a1a"
  error-soft: "#ffdad6"
  add: "#e4f2d6"
  remove: "#fbe6e3"
  focus: "#386663"
  dark-bg: "#10140f"
  dark-surface: "#161b13"
  dark-subtle: "#262a24"
  dark-ink: "#e1e4dc"
  dark-muted: "#c5c8bd"
  dark-border: "#45483f"
  dark-primary: "#b7f34a"
  dark-on-primary: "#203600"
  dark-primary-soft: "#304f00"
  dark-error: "#ffb4ab"
  dark-error-soft: "#4e2521"
  dark-add: "#273920"
  dark-remove: "#452824"
  dark-focus: "#a0d0cb"
typography:
  headline-compact:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "1.3rem"
    fontWeight: 650
    usage: "窄屏标题与品牌标识"
  headline:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "1.6rem"
    fontWeight: 650
    lineHeight: 1.4
    letterSpacing: "-.02em"
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "1.05rem"
    fontWeight: 650
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "14px"
    lineHeight: 1.55
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "14px"
    fontWeight: 550
  code-editor:
    fontFamily: "ui-monospace, SFMono-Regular, Consolas, monospace"
    fontSize: "13px"
    lineHeight: 1.75
  code-diff:
    fontFamily: "ui-monospace, SFMono-Regular, Consolas, monospace"
    fontSize: "12px"
    lineHeight: 1.7
rounded:
  radius: "12px"
  small-radius: "8px"
spacing:
  space-1: "4px"
  space-2: "8px"
  space-3: "12px"
  space-4: "16px"
  space-6: "24px"
  space-8: "32px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label}"
    rounded: "{rounded.small-radius}"
    padding: "8px 16px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.small-radius}"
    padding: "8px 16px"
  button-secondary-hover:
    backgroundColor: "{colors.subtle}"
  pane:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.radius}"
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.small-radius}"
    padding: "8px 12px"
  example-action:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.small-radius}"
    padding: "4px 12px"
  code-editor:
    backgroundColor: "{colors.subtle}"
    textColor: "{colors.ink}"
    typography: "{typography.code-editor}"
    padding: "16px 24px"
  code-diff:
    backgroundColor: "{colors.subtle}"
    textColor: "{colors.ink}"
    typography: "{typography.code-diff}"
    rounded: "{rounded.small-radius}"
    padding: "12px"
---

# Design System: Veer AI Editor

## Overview

**Creative North Star: "可确认的编辑工作台"**

这是当前原型的描述性概括，而非另立品牌身份。视觉继承 PRODUCT.md 已确认的 Veer 语气：清晰、安静、可靠、轻量，以及已有 Android 绿色 Material 调色板。界面以 Operate 为主：一侧编辑稿，一侧指令与修改审阅；不是营销页面，也不是聊天消息流。

边界、文字层级和色调分区服务于检查与确认。完整代理软件方向仍保留，但本原型没有 VPN、实时运行状态、测速、服务解锁或运行时自动应用能力。未来扩展应复用视觉语言，不应把当前编辑器的双栏排布视为所有产品页面的永久结构。

**Key Characteristics:**

- 安静的绿色强调色与略带绿色的中性色。
- 系统 UI 字体配真正代码等宽字体。
- 编辑稿、规则修改账本、文本 Diff 与确认操作明确分区。
- 浅色、深色与紧凑移动端共用语义角色。
- 平面、描边、无动效。

依据：public/style.css、public/index.html、public/app.js，以及 artifacts/desktop.jpg、artifacts/mobile-dark.jpg。此文档仅约束 prototype/ai-editor；不替代仓库根级设计系统。

## Colors

颜色以 CSS 自定义属性为实现源；frontmatter 为其浅色值与 dark-* 对应值的可移植记录。切换深色时重映射同名 CSS 属性，不把两套颜色混用。

### Primary

- **Veer 橄榄绿 / 明亮叶绿**：primary 与 dark-primary 用于主操作、品牌标志、成功文字与完整出口名称。前景分别为 on-primary、dark-on-primary。
- primary-soft 与 error-soft 已声明，但当前界面未使用；记录现有令牌不意味着新增容器变体。

### Neutral

- bg / dark-bg 是页面底色；surface / dark-surface 是面板和输入背景。
- subtle / dark-subtle 承载 YAML 与 Diff，让文本编辑区域区别于操作区。
- ink / dark-ink 是正文；muted / dark-muted 是帮助、元信息和次要说明；border / dark-border 是轮廓和分隔线。
- Web 白色 surface 与深色 surface 是当前原型自己的实现，不等同于 Android 的全部 surface 角色。不要把整套 Android 色表原样复制过来。

### Semantic

- error / dark-error 用于错误状态文字，不代表网络连接状态。
- add / dark-add、remove / dark-remove 用于 Diff 行背景；行首同时保留 + / −，不能只靠红绿判断修改。
- focus / dark-focus 是青绿焦点环；它是交互可见性颜色，不是第二品牌强调色。

## Typography

UI 字体使用系统栈：-apple-system、BlinkMacSystemFont、Segoe UI、PingFang SC、Microsoft YaHei、sans-serif。代码字体使用 ui-monospace、SFMono-Regular、Consolas、monospace。不加载网络字体，也没有独立展示字体。

层级来自实际 CSS：

- 页面标题：1.6rem、650、1.4 行高、−.02em 字距；480px 以下为 1.3rem。
- 面板标题：1.05rem、650；修改预览标题为 1rem。
- 正文：14px、1.55 行高；按钮与字段标签为 550。
- 帮助文字：.86rem、1.65 行高；状态 .9rem；页脚 .8rem。
- YAML 编辑稿：13px / 1.75；Diff：12px / 1.7；账本匹配项：12px 等宽。
- 普通文本输入继承 UI 字体，textarea 默认 1.7 行高；只有 YAML 与 Diff 采用代码字体。

不要用视觉相似的比例字体替代等宽代码栈，也不要把操作说明写成装饰性大标题。

## Layout

页面容器最大宽度 1500px，居中，桌面内边距 32px。顶栏 72px 高、左右 32px。页面标题与工作区相隔 24px。桌面工作区使用 minmax(0,1.1fr) 与 minmax(0,1fr) 两列，间距 24px；面板顶端对齐，独立随内容增长。

面板标题、工具条和页脚通常左右 24px；助手正文 24px。4 / 8 / 12 / 16 / 24 / 32px 是已实现间距尺度。

- **900px 以下**：容器内边距 24px，工作区单列，编辑稿在前；隐藏“编辑器原型”标记，页脚纵排。代码区高 340px，最小高 280px。
- **480px 以下**：容器与面板横向内边距 16px，顶栏高 64px；隐藏品牌附注及外观可见标签，保留外观 select 的可访问名称。出口选择纵排且全宽；确认动作平分可用宽度。
- 桌面 YAML 区最小高 485px、高 calc(100vh - 420px)、最大高 900px，可竖向调整；移动端沿用可调整行为。
- 账本最大高 280px，Diff 最大高 320px；局部滚动保持操作区可读。YAML 和 Diff 保留预格式文本并允许横向滚动；不强制换行破坏缩进。

## Elevation & Depth

没有阴影、渐变、模糊或悬浮层级。层次来自 bg → surface → subtle 的色调变化、1px border 分隔线和间距。当前 CSS 与脚本没有动画或过渡；主题与状态直接切换。不要把解析防抖的 250ms 当成视觉动效令牌。

## Shapes

面板统一 12px 圆角，1px 描边，overflow:hidden；按钮、输入、select 与 Diff 容器 8px 圆角。YAML 编辑区位于面板内，自身无描边、无圆角。没有胶囊形导航、装饰性卡片或图像背景。

## Components

### Buttons

主按钮使用 primary / on-primary；次按钮使用 surface / ink 与 border。普通按钮最小高 40px、8px 16px 内边距、550 字重。次按钮悬停变 subtle；主按钮悬停保持原色并 brightness(.94)。禁用状态 opacity:.5、not-allowed 光标。没有点击位移或动画。

所有可聚焦交互控件保留 2px focus 描边、3px 外偏移；代码区使用 −3px 内偏移。输入控件不能以禁用色替代真实 disabled 属性。

### Example Actions

示例指令是小型按钮而非选中标签：.86rem、最小高 36px、4px 12px 内边距、8px 圆角，可折行排布。点击会写入指令并聚焦输入，没有持久选中状态。

### Panes and Fields

编辑稿与指令面板共享 surface、border、12px 外圆角；标题栏至少 72px 高。input / select 最小高 38px、8px 12px 内边距；textarea 全宽、12px 内边距、可竖向调整。提示文字为 muted、opacity:.85。AI 设置是可展开 details，不是独立浮层。

### Navigation

顶栏仅承担 Veer 标志、编辑器名称与外观选择。品牌图标使用内联 SVG 和 primary 色；没有侧栏或多页面选中状态。外观支持系统、浅色、深色；跟随系统使用 prefers-color-scheme，当前选择不持久化。

### Modification Ledger and Diff

修改账本以无序列表呈现：12px 纵向内边距与分隔线；匹配类型、匹配项用等宽字，完整出口名使用 primary 与 600 字重，原规则说明单独一行 muted。它不是网络节点性能列表。

Diff 使用可折叠 details，默认展开；subtle 底、8px 圆角、12px 内边距。新增/删除行整行着色并带字符前缀。超过 8 行的未修改片段保留首尾各 3 行和省略说明。必须与自然语言账本并存，便于检查精确修改和目的地。

### Review and Confirmation

空预览有轻量线框文档图标和“先看改动，再确认”。生成中用按钮文案与状态文字表达，无旋转加载动画。确认只更新编辑稿；失效预览清除，失败检查禁用确认。桌面确认区右对齐，480px 以下按钮等宽。反馈是行内 aria-live 状态，而非 toast。

## Do's and Don'ts

- Do 沿用 CSS 语义令牌并同步维护浅色与深色。
- Do 将匹配项、完整出口名称、原规则与 Diff 放在确认动作之前。
- Do 保留显式焦点、真实禁用状态及文字状态反馈。
- Do 用 UI 字体写指令和说明，用等宽字体写 YAML、Diff 与规则匹配项。
- Do 保持代码局部滚动和移动端单列，让确认动作仍可阅读。
- Don't 将“检查通过”“绿色成功”或演示节点解释为网络可达、解锁或测速证据。
- Don't 将“确认到编辑稿”改写成已应用到代理或已连接 VPN。
- Don't 加入未经实现的阴影、动效、选中 chips 或运行时仪表。
- Don't 把本原型的操作布局强加为未来完整代理软件的唯一页面结构。
