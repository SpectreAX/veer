# Veer macOS AI Editor

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

macOS 原生 SwiftUI 界面；不是网页包装。沿用同一 Veer 产品的编辑行为。

## Users

希望通过自然语言编辑 Mihomo 网站/服务分流的用户，不希望模型读取节点与密钥配置。

## Product Purpose

导入 Mihomo 配置后，以自然语言修改网站/服务分流，审阅出口与规则差异，再确认、撤销或导出完整配置副本。后续仍考虑完整 AI-powered 代理软件。

## Capabilities and Constraints

用户确认 OpenCode 参考原型并要求「开始落地」：保留 Codex 式导入画布，未导入时中央液态玻璃加号与底部导入提示；导入后主对话展示真实处理记录、出口摘要和紧凑文件条目，点击条目打开同轮详细审阅。宽窗口并排，紧凑窗口只呈现审阅区域；关闭后保留原历史阅读位置与每轮匹配范围展开状态。旧结果可读不可重确认，单轮撤销只允许当前快照栈顶。支持本地 UTF-8 Mihomo YAML 与直接返回 YAML 的 HTTPS 配置/订阅链接（最大 2 MB）；不自动跟随重定向，不转换 Base64/节点 URI 列表。

原生版复用另行运行的本机规则服务（127.0.0.1:4317），不是独立内置代理内核。完整配置只在本机内存解析并交给 loopback 服务；AI 只接收匿名出口名称、推断/声明地区与匿名化用户指令，不接收完整配置、原规则、节点字段或 Provider URL。用户自己输入的任意秘密无法保证自动识别，因此对话框明确提醒勿填密钥/订阅链接。API Key 可保存于系统钥匙串或仅供会话，界面只恢复已保存状态布尔值，不回填秘密。处理记录只呈现真实任务状态；成功流程三步，不模拟原型四阶段或模型内部推理。

只修改 rules，保留其他字段原文；导出副本明确拒绝导入原文件及其路径别名/同文件身份。草稿与对话不持久保存，重新导入或关闭前有未保存变化时提示。地区标签非实测；占位出口的内核检查只覆盖修改规则，不证明完整配置有效或网络可达。不连接 Controller，不启动 VPN，不重载正在运行的代理。

## Brand Commitments

Veer 名称、清晰安静可靠的工作台，保留绿色标识。用户指定的导入画布与对话/按需审阅表达在同一原生视觉世界内增量落地；使用 macOS 原生控件、系统语义色与真实 Liquid Glass 操作层，正文实底，不照搬 Android 卡片。

## Evidence on Hand

2026-10-14：29 项 Swift Tests 通过（VeerMac 15 / VeerEditor 14），Release 构建与 ad-hoc 签名验证通过；独立原生 UI 终审 SHIP。原生浅深色、默认/最小窗口、历史位置恢复、按 turn 披露持久性、旧记录只读、当前候选确认与栈顶撤销守卫已验证。完整导出经 YAML 解析确认当前 10 条美国服务规则与 MATCH，非 rules 前缀逐字保留。截图见 `artifacts/opencode-2026-10-14/`；合同见 `../../docs/MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md`。

此前 2026-10-11 文件/公开 HTTPS YAML 导入与完整导出、43 项 Node 回归和 Swift 20 项通过/1 项跳过是历史证据，详见 `../../docs/MACOS_IMPORT_CONVERSATION_2026-10-11.md`。本轮不冒充已重跑这些旧轮检查。未测试真实 AI/真实订阅/钥匙串值、真实网络可达性、VoiceOver、macOS 14 与系统 Reduce Transparency。公开分发签名/公证未完成；ad-hoc 签名不等于公开发行就绪。
