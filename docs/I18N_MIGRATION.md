# Veer i18n 迁移计划与阶段验收

> 更新于 2026-07-31 23:52

## 目标与约束

Veer 使用 Android 原生字符串资源实现国际化：默认 `values` 提供英文，`values-zh`
提供中文。界面层在组合时解析资源，长期状态和 ViewModel 不保存已经翻译的字符串。

以下内容不翻译：

- 用户输入的 AI prompt、订阅/profile 名称、节点与策略组名称；
- AI 历史中的原始结果、实际规则和网络诊断证据；
- Mihomo 协议字段、日志正文、域名、IP、错误原文。

这些值属于用户数据或诊断证据，翻译会改变语义并影响问题复现。

## 第一阶段（已通过）

迁移范围：

1. Manifest 中全部 Activity 标题；
2. Main 首页、连接状态卡、AI 执行按钮和运行日志标题；
3. VPN 启动进度的全部真实里程碑；
4. AI 快捷模板标题/prompt、历史来源/状态/操作；
5. Settings 全页、三档主题、API Key 状态、DNS/Per-App 摘要；
6. HyperOS/Android 后台保护状态、原因和系统设置入口。

实现原则：

- 所有带参数文案使用带位置编号的格式参数，例如 `%1$s`、`%2$d`；
- `HomePrimaryActionUi`、`StartupProgressUi`、`SettingsText` 等模型只保存 `@StringRes`
  和原始数值；
- `localeConfig` 只声明已实际提供的 `en`、`zh`；
- 品牌名、API 名称和单位不做无意义翻译。

## 第一阶段验收结果

- 英文与中文各 150 个同名字符串，Lint 未报告缺失翻译或格式不一致；
- 175/175 单元测试通过；Android 16.1 完整 instrumentation 为 `OK (21 tests)`；
- Android 16.1 实际切换 `en-US` / `zh-CN` 后，主页和设置页无需重装即可切换；
- HyperOS 真机资源解析专项通过，保数据安装后 VPN 恢复 `Running`；
- 第一阶段目标 Kotlin 文件中的中文硬编码数为 0；全 UI/状态层存量由 438 降到 298。

## 第二阶段进度：Profile（已通过）

Profile 主列表、详情页和两个 ViewModel 已完成迁移：导入、刷新、重命名、删除、订阅用量、
激活/回滚阶段和失败提示均在界面组合或 `Context` 可用时解析。新增通用 `UiText`，状态层保存
资源 ID、原始参数或嵌套 `UiText`，从而支持语言切换，也能正确组合“启动超时”等本地化阶段名。

本批验收：

- 英文与中文资源各 230 个且名称集合完全一致，无重复项；Profile 包中文硬编码为 0；
- 175/175 单元测试、Lint、Debug 与 AndroidTest 构建通过；Android 16.1 完整
  instrumentation 为 `OK (22 tests)`；
- 模拟器实际显示英文 `Profiles / Subscription URL / Saved profiles` 与中文
  `配置 / 订阅链接 / 已保存配置`；
- HyperOS 真机以保数据方式覆盖安装，Profile 双语与嵌套状态资源测试 2/2 通过，测试后 VPN
  已恢复 `Running`；
- UI 层中文硬编码存量由 298 降到 237。本阶段不翻译 URL、YAML、DNS、用户配置名与解析器
  返回的原始错误证据。

## 第二阶段进度：DNS（已通过）

DNS Activity、ViewModel 与校验策略已经迁移。核心校验器不再生成任何语言的展示文案，
而是返回 `DnsValidationProblem` 类型和格式参数；Compose 层负责将必填、协议、端口、路径、
凭据等 13 类问题转换为当前语言。保存、停止、应用、启动、回滚和运行状态继续使用延迟解析
的 `UiText`，原始核心异常只作为不翻译的证据参数保留。

本批验收：

- 英文与中文资源各 299 个且名称集合一致；DNS UI、ViewModel 与校验策略中文硬编码为 0；
- 175/175 单元测试、Lint、Debug/AndroidTest 构建通过；Android 16.1 完整 runner
  `OK (23 tests)`；
- Android 16.1 分别在 `en-US` 与 `zh-CN` 下完成自定义 DNS、Redir Host 和保存/安全重连
  按钮的 Compose 交互验证；DNS 资源、校验格式和嵌套运行状态专项 3/3 通过；
- HyperOS 真机保数据安装后同一专项 3/3 通过，未写入或修改真实 DNS，VPN 已恢复
  `Running`；
- UI 层中文硬编码存量由 237 降到 183。URL scheme、DoH/DoT、协议名与实际端点保持原样。

## 第二阶段进度：Rules（已通过）

Rules Activity、ViewModel 和 `AiRulePresentation` 已完成迁移。展示模型使用可嵌套 `UiText`
描述规则匹配范围、流量出口和路由摘要；`GEOSITE`、域名、CIDR、规则集、实际节点名与策略组
原值保持不变，只翻译其周围的解释文案。DIRECT、REJECT 及常见地区缩写仅在展示层增加明确
说明，不修改写回 Mihomo 的 policy。

本批验收：

- 英文与中文资源各 347 个且名称集合一致；Rules 包中文硬编码为 0；
- 175/175 单元测试、Lint、Debug/AndroidTest 构建通过；Android 16.1 完整 runner
  `OK (25 tests)`；
- Android 16.1 在 `en-US` 与 `zh-CN` 下分别完成规则卡片、健康状态、“更改出口”和策略选择
  对话框交互；同一条原始 `GEOSITE,netflix,HK` 分别显示为
  `Netflix → Hong Kong (HK)` 与 `Netflix → 香港（HK）`；
- HyperOS 真机保数据安装后双语资源与规则展示专项 4/4 通过，未修改真实 AI 规则，VPN 已
  恢复 `Running`；
- UI 层中文硬编码存量由 183 降到 134。

## 第二阶段进度：Nodes（已通过）

Nodes Activity、ViewModel 与 `DelayPresentation` 已完成迁移。页面标题、筛选器、批量测速、
节点健康状态和操作结果使用当前语言；节点名、策略组名、代理类型、地区代码与实际延迟数值
保持原样。延迟展示也改为延迟解析的 `UiText`，避免 ViewModel 或展示模型提前固定语言。

本批验收：

- 英文与中文资源各 382 个且名称集合一致；Nodes 包中文硬编码为 0；
- 175/175 单元测试、Lint、Debug/AndroidTest 构建通过；Android 16.1 完整 runner
  `OK (27 tests)`；
- Android 16.1 在 `en-US` 与 `zh-CN` 下分别验证默认/延迟/地区筛选、隐藏不可用节点、
  一键测速入口与延迟标签；`JP`、`HK`、`Tokyo A` 等原始数据保持不变；
- HyperOS 真机保数据安装后双语资源与节点消息专项 5/5 通过，未执行真实节点切换或批量测速，
  VPN 已恢复 `Running`；
- UI 层中文硬编码存量由 134 降到 99。

## 第二阶段顺序

| 顺序 | 页面/层 | 当前中文字符串数 | 验收重点 |
|:--|:--|--:|:--|
| 1 | Profile 主列表/详情 + ViewModel | 0（完成） | 导入、激活、刷新、用量和失败信息已验收 |
| 2 | DNS Activity + ViewModel + Validator | 0（完成） | 类型化校验和安全重连状态已验收 |
| 3 | Rules Activity/ViewModel/Presentation | 0（完成） | 原始规则保持不变，双语展示与改绑入口已验收 |
| 4 | Nodes Activity/ViewModel/Presentation | 0（完成） | 节点原值不变，筛选/延迟状态已验收 |
| 5 | Per-App Activity + ViewModel | 27 | 应用名/包名不翻译 |
| 6 | Logs Activity + ViewModel | 21 | 日志正文不翻译，工具栏和过滤器双语化 |
| 7 | Connections Activity + ViewModel | 20 | host/rule/chain 不翻译 |
| 8 | SpeedChart/AppDestination/HomeUiState | 9 | 单位、空状态和导航名 |

`ui/VeerApp.kt` 仍有 30 个中文字符串。该文件疑似旧入口；第二阶段先确认生产调用关系，
若已无入口则删除，若仍使用则随单 Activity + Compose Navigation 一并迁移，避免为废弃 UI
制造重复资源。
