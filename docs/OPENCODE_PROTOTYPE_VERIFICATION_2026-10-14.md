# OpenCode 参考交互原型：验收记录

目标：`prototype/opencode-review/`。仅合成数据、无真实请求。用户已确认可收起右侧审阅构图。入口：<http://127.0.0.1:4318/>。

## 已执行

- 独立 buildless HTML/CSS/ES modules，不新增依赖；HTTP 入口 200。`connect-src 'none'` 阻止网络请求。
- Node 状态测试 5 项通过；`node --check app.mjs` 通过。包括多服务确认/撤销、取消迟到结果、旧候选失效、失败不写入、栈顶撤销边界。
- 浏览器：内置文件示例导入、Netflix→日本＋ChatGPT→美国的 10 条候选、确认后草稿 10 条、撤销后草稿 0 条。
- 浏览器：失败留在对话、取消不写入、后续候选使旧候选失效、浅深色直接切换。
- 浏览器：390px 配置菜单可进入规则稿；确认长香港出口后生成 6 条演示规则，导出演示副本成功。下载为 `/Users/spectreax/Downloads/veer-demo-edited.yaml`，含“合成演示配置”注释、6 条香港规则及 MATCH,DIRECT；不含节点或密钥。
- 浏览器运行 error 日志为空。1080 / 390 宽度未出现整个文档横向溢出；Diff 内部横向滚动是预期行为。

## 视觉证据

文件位于 `prototype/opencode-review/artifacts/`，已打开检查有效性：

- `desktop-dark.jpg`：1440 × 900，深色候选对话与审阅。
- `desktop-light.jpg`：1440 × 900，浅色候选对话与审阅。
- `narrow-review.jpg`：1080 × 760，单区域审阅。
- `mobile-long.jpg`：390 × 844，长出口换行、单行 Diff 与确认动作。

首次视觉检查发现动态 SVG 放大问题，已统一 icon 尺寸。一次 detector 提示 10px 功能文本与 11px 正文，已机械提升至 12px，再捕获上述最终证据；未重复运行 detector。

## 尚未证明

- 未运行 OpenCode v2 本身，不能做同尺寸源/目标画面对比；这是固定源码参考的 Veer 原型，不宣称像素级克隆。
- Glass 是 CSS 示意，不是 SwiftUI 原生 Liquid Glass。
- 导入两种入口均载入内置示例，URL 不下载、文件不读取；演示计时不是真实 AI 阶段。复制剪贴板、真实辅助技术与旧 OS 未实测。
- SwiftUI 代码、原生构建和真实规则服务均未改动，不把本次 Web 原型验收当成原生程序通过。
- 独立终审初次 disposition 为 fix；下述 3 项修正完成后，逐项 verdict 为 ship，仅覆盖列出的修正，不扩大为 OpenCode 视觉忠实度结论。

## 独立终审与修正

| 项目 | 修正 | 复验 | Verdict |
| --- | --- | --- | --- |
| 窄窗口返回丢历史位置 | 可见布局时保留独立 chatTop，隐藏事件不得写入零；键盘滚动暂停跟随 | 稳定非零位置 120→打开审阅→返回→120；`history-restored.jpg` | resolved |
| 服务范围展开状态丢失 | turn ID＋服务名记录 disclosure 状态，导入/重置时清除 | 展开 Netflix 范围→确认→关闭→重新打开，open=true；`range-preserved.jpg` | resolved |
| 放弃后仍像处理中 | discarded 有独立文案与标签 | 显示“已放弃此次候选，草稿未改变。”；`discarded.jpg` | resolved |

补充截图均为 1080 × 760，已打开确认内容有效。初次历史键盘测试取样过早（Home 的滚动未稳定），没有将其当作通过证据；复测在稳定非零位置进行。

文件与 URL 演示入口均验证；URL 示例来源标题为「订阅配置.yaml」，不发起请求。交付停在 10 条待确认候选，截图 `handoff.jpg`（1440 × 900）；空态补充为 `landing-dark.jpg`。所有截图来自实际本地页面，不是生成图片。

补充空态验收修正了共享 icon 选择器覆盖大加号的 CSS 优先级问题，读取实际 computed width 为 56px；已重新捕获并打开 `landing-dark.jpg` 确认。没有改变既定按钮或字形尺寸令牌。

clone-website 影响：固定参考提交、来源映射、真实状态和未观察差异分开记录，不以 iframe 或截图作为实现。
impeccable 影响：按已确认构图制作原型、实际浅深色/窄屏检查、独立修正复核；当前程序和其旧设计索引不作隐式刷新。

独立 documenter 已将实际原型令牌/组件记录到 `prototype/opencode-review/DESIGN.md` 和该目录内 `.impeccable/design.json`；JSON/v2 结构、颜色与 CSS 引用完成核对。只写原型文档，没有更新原生设计文件或其既有索引。

原型经用户审阅后，才开始计划的原生落地阶段。
