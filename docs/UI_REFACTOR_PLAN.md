# Veer UI 重构执行计划

日期：2026-08-05

## 目标

依据根目录 `AGENTS.md`，在不改变代理、配置、AI 与 VPN 业务行为的前提下，把现有 Compose UI 渐进迁移到统一的 Veer Design System。每个阶段必须通过编译与自动化检查，并使用 Preview 和运行截图验证浅色、深色、长文本与窄屏状态。

## 基线审计

- `testDebugUnitTest`、`lintDebug`、`assembleDebug`：通过。
- 当前只有首页文件包含一个 Preview，其余主要页面缺少独立 Preview。
- Theme 同时存在 Material 默认紫色动态配色和首页固定深色 Lime 配色，浅色主题下视觉语义不统一。
- Feature UI 中存在约 350 处直接 `dp`、`sp`、颜色、圆角或字重值；首页、节点、配置、规则最集中。
- 设置项、卡片、顶部栏、状态提示和输入框在多个页面重复实现。
- 多数页面已有 ViewModel/UiState，可在保持业务行为的前提下先拆出无状态 Screen，再补齐 Preview 状态。

## 迁移顺序与验收证据

1. Theme 与 Tokens
   - 浅色/深色固定 Veer 品牌配色。
   - Spacing、Shapes、Elevation、Motion、Typography 和扩展状态色集中定义。
   - Preview wrapper 覆盖 Light、Dark、Small width、Large font。
2. 公共组件
   - Primary/Secondary Button、Card、TopAppBar、StateView、SettingsRow、StatusBadge、TextField、Dialog。
   - 每个组件提供 Light/Dark Preview，并覆盖 Loading、Disabled 或 Error 等适用状态。
3. 首页
   - 第一视觉为连接状态，唯一主操作为连接/断开。
   - AI 输入区明确展示解析、预览、应用/取消，不静默应用。
4. 节点列表
   - 选中、测速中、未测速、超时、不可用均有非纯颜色表达。
5. 配置导入与管理
   - URL、剪贴板、文件与现有导入能力使用统一输入/状态组件；错误靠近输入区且可恢复。
6. 设置页
   - 按连接、代理规则、节点与订阅、系统集成、外观、日志与诊断、关于分组。
7. 日志页
   - 搜索、筛选、暂停、复制、导出和空/错误状态统一。
8. 其余页面
   - 规则、DNS、连接、分应用代理、配置详情及调试 UI。
9. 完成审计
   - 全量 JVM 测试、Lint、Debug/AndroidTest/Release 构建。
   - 模拟器运行截图：Light、Dark、窄屏、长文本。
   - 搜索确认 Feature 层不再出现未登记的颜色、字号、圆角和任意间距。

## 页面规格摘要

### 首页

- 页面目标：让用户第一眼确认连接状态、节点和模式，并安全执行连接或 AI 分流。
- 主要操作：连接/断开。
- 次要操作：AI 指令、查看节点、模式、流量和诊断。
- 状态：Stopped、Starting、Running、Stopping、Error、Disabled、长文本、小屏。

### 节点

- 页面目标：查看实时策略组和节点质量并快速切换。
- 主要操作：选择节点；批量测速为次级操作。
- 状态：Loading、Empty、Disconnected、Normal、Probing、Partial failure、Error。

### 配置

- 页面目标：导入、检查、激活、刷新和管理配置。
- 主要操作：导入或激活当前上下文中的配置。
- 状态：Idle、Parsing、Success、Failure、Duplicate/Invalid、Network error、Empty。

### 设置

- 页面目标：按用户任务组织可理解的连接与应用偏好。
- 主要操作：保存当前设置；导航操作保持次级。
- 状态：Normal、Disabled by runtime、Validation error、Applying。

### 日志

- 页面目标：让普通用户定位运行问题并可复制或导出证据。
- 主要操作：筛选/搜索；导出为次级操作。
- 状态：Loading、Empty、Normal、Paused、Error、Long line。

## 边界

- 不改变 VPN 生命周期、配置格式、AI 执行语义或 Mihomo 控制器调用。
- 不升级无关依赖，不引入大型 UI 框架。
- 原始节点、配置、策略组名称不做本地化或改写。
