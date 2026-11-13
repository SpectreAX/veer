# Veer：OpenCode UI / 交互参考改造计划

日期：2026-10-14。平台：macOS 原生 SwiftUI。目标：以 OpenCode 的应用工作台为参考改善配置编辑体验，不复刻 GitHub 仓库页、终端界面或品牌。

## 范围与约束

- 主任务：导入配置 → 对话提出分流修改 → 查看真实处理状态 → 审阅出口与 Diff → 确认到草稿 → 撤销／导出副本。
- 保留现有 SwiftUI、系统语义色、SF Symbols、Liquid Glass 操作层；内容与代码区保持实底。
- 完整配置留在本机，AI 只使用匿名出口与指令；不读取真实订阅/API Key，不测试真实 AI 请求，不触碰用户未保存的窗口。
- 本次不改变规则解析、密钥持久化、本机编辑服务、Android 或代理内核。服务随应用打包是独立后续工作。
- 不新增 OpenCode 的 shell、文件系统工具、任意代码执行权限；不展示虚构模型思维链。

## 执行与每阶段验收

| 阶段 | 交付 | 验收门槛 | 初始状态 |
| --- | --- | --- | --- |
| 0 技能 | 安装 clone-website、读取观察指南 | SKILL.md 与引用文件存在；安装来源明确 | 已完成 |
| 1 参考研究 | 固定 v2 提交、应用 UI 结构与样式/交互来源清单 | 区分源码证据、真实画面与尚未观察行为；不得声称像素级复刻 | 源码研究完成；真实画面待补 |
| 2 交互原型 | 独立、合成数据、无 API 的可点击原型 | 导入、发送、处理中/取消、Diff、确认、撤销、错误与外观切换可演示；长文与窄宽度检查 | 已完成；入口 127.0.0.1:4318 |
| 3 审阅 | 用户确认构图与交互 | 原型审阅后才替换现有原生界面；未确认保留当前程序 | 用户要求“开始落地”，已确认进入原生实施 |
| 4 原生落地 | 改造 EditorView / ConversationTurnView，复用 model 与公共材质 | 自动化测试、Release 构建、独立原生演示窗口检查、未保存内容不丢失 | 已完成；29 项 Swift Tests 与 Release/ad-hoc 签名通过 |
| 5 交付 | 验证记录、已完成/差异/限制 | 浅深色、长文件名/出口、最小窗口、历史滚动、取消、确认/撤销/导出均记录；未实测单列 | 已完成；独立原生终审 ship，未实测项见验收记录 |

## 信息层级（待参考研究细化）

- 侧栏：当前配置与编辑入口；不新增虚构“已保存会话”。
- 中央：对话与简明结果；状态表示真实操作进度，不伪造 Thinking 内容。
- 审阅：服务→出口、规则数量、验证限制与 Diff；确认结果写明“已写入草稿，未应用代理”。
- 底部：指令输入、解析模式、发送/取消。未导入时保留导入提示与中央加号。
- 次要动作：检查、导出、外观与设置。高频入口可达，低频设置不抢正文。

## 复用与文件责任

- `native/macos/Sources/VeerMac/EditorView.swift`：导航、首页、composer、导入 sheet。
- `ConversationTurnView.swift`：阶段、结果、出口、紧凑文件条目。
- `ConversationReviewView.swift`：选中 turn 的出口范围、共享 Diff、确认/丢弃/撤销。
- `ConversationScroll.swift`：跟随/阅读历史状态。
- `WorkbenchStyle.swift`：共享尺寸、材质、按钮。
- `EditorModel.swift` / `Sources/VeerEditor`：业务与安全边界不重写。
- 独立原型目标目录：`prototype/opencode-review/`，不替换现有编辑服务页面。

## 参考与许可

- OpenCode：<https://github.com/anomalyco/opencode/tree/v2>。
- 参考提交：`4617210822bdbb31e5749751afbfb4584ccedac8`（git ls-remote 观察）。
- clone-website：<https://github.com/JCodesMore/ai-website-cloner-template/tree/master/.agents/skills/clone-website>，安装位置 `/Users/spectreax/.codex/skills/clone-website`。
- 读取源码前后记录许可；不拷贝 OpenCode 标识与产品宣称，直接复用代码时保留相应许可。

第一阶段以源码只读研究为主，不运行未知远端脚本；若无法获得真实 UI 画面，先交付带差异声明的参考原型，不宣称完成克隆。

## 本轮执行记录

- clone-website 安装并核对引用文件完成；用户同意后 Impeccable 更新到 4.5.2，新版下一轮生效。
- 固定 v2 检出、应用与审阅组件、布局/主题声明、MIT 许可已检查。
- 来源、Veer 适配与未验证项详见 `OPENCODE_UI_REFERENCE_2026-10-14.md`。
- 遵循 impeccable 的 shape 规则：先确认“主对话 + 可收起审阅区”的构图，再制作原型；本轮没有替换 SwiftUI 或运行参考代码。

### 原型阶段执行结果

用户随后确认构图，已完成 `prototype/opencode-review/`，独立于编辑服务与 SwiftUI。5 项 Node 状态测试通过；浅深色、1080 单区域、390 长出口与 Diff、确认/撤销/失败/取消及演示副本导出完成浏览器验收。独立终审提出 3 项交互修正，均通过逐项复验，修正范围 verdict 为 ship；不宣称像素级复刻或原生版本已通过。详情见 `OPENCODE_PROTOTYPE_VERIFICATION_2026-10-14.md`。

### 原生落地执行结果

用户要求“开始落地”后，已完成主对话＋按需审阅的 SwiftUI 实施。宽窗口并排，窄窗口单区域审阅；关闭后保留历史滚动位置与各轮范围展开状态。当前候选可确认，历史候选只读，撤销仅针对匹配的栈顶修改。

29 项 Swift Tests、Release/ad-hoc 签名、独立原生副本的浅深色、长出口、最小窗口、确认、旧结果只读和完整副本导出验证通过；取消/失败由整合测试覆盖。独立原生终审结论为 scoped UI ship，不代表公开发行签名或真实 AI 请求已验证。详见 `MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md`。

用户原窗口未强制关闭或替换；新版应用已构建，本机编辑服务仍需运行。
