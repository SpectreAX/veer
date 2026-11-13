# Veer AI Editor

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

本地 Node.js 服务与原生 HTML/CSS/JavaScript。作为现有 Veer 项目内的可逆原型实现选择；使用 YAML 文档树保留配置。用户未指定 Web 框架。

## Users

已有 Mihomo 配置，希望用中文或英文调整网站、服务分流的用户。

## Product Purpose

用户已确认第一版聚焦“Netflix 走日本、ChatGPT 走美国”等网站/服务分流。通过导入、指令、差异预览、确认、撤销和导出验证 AI 编辑价值。后续仍计划开发 AI-powered 完整代理软件。

## Operating Context

原型在 Mac 本机浏览器运行，这是为快速验证作出的实现假设。配置可来自本地文件或粘贴；示例数据明确标为演示。AI 服务通过用户输入的 OpenAI-compatible API 设置连接。

## Capabilities and Constraints

- 当前实现只修改分流规则；节点、组、Provider、DNS、监听器及未知字段须保持原始语义。
- 默认独立规则模式只接收手工登记组名与地区、rules 片段。没有节点导入；完整 YAML 编辑在高级模式。
- 生成受限结构化计划，由确定性代码应用。独立模式匿名出口编号在本地映射回登记名称；高级模式出口从完整配置解析。
- 独立模式 AI 上下文仅包含匿名出口、声明地区和替换组名后的指令；高级模式仍发送真实出口名称和类型。两者都不发送整份 YAML 或节点凭证。配置不持久化；用户要求 API Key 可保存到 macOS 系统钥匙串，按地址隔离，不回传页面。
- 没有实时代理运行状态、测速或流媒体解锁数据。模糊或需要实时信息的要求应澄清。
- Mihomo 配置测试与编辑器结构检查分别展示；配置测试成功不等于网络出口可用。
- 完整代理方向保留；此阶段没有 VPN 和运行时自动应用功能。

## Brand Commitments

继承 Veer 已有清晰、安静、可靠、轻量的产品语气和绿色 Material 色彩。

## Evidence on Hand

现有 Android AI 模块：`app/src/main/java/com/yamax/veer/core_ai/`。现有设计令牌：`app/src/main/java/com/yamax/veer/ui/designsystem/theme/VeerColors.kt`。原型端到端 AI 调用需用户在界面提供可用 Key；测试不复用历史对话凭证。

## Product Principles

- 先看具体修改，再确认结果。
- 明确写出流量出口名称，不只显示服务名。
- 缺少证据时说明限制，不猜测节点质量。
- 编辑引擎与执行环境分开，方便未来接入 Android 和运行中的 Mihomo。
