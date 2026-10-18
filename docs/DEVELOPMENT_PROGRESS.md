# Veer 功能开发进度汇总

> 当前编辑器进度更新于 2026-10-14；以下 Android 轮次为历史记录。

## 当前方向：AI 配置编辑器

已从完整 VPN 客户端转向先验证 AI 编辑能力，保留 Android 客户端代码，不在本轮更改代理内核。Web 本机编辑服务与 macOS 原生 SwiftUI 客户端已落地，支持完整 YAML 文件／订阅 URL 导入、匿名出口上下文、网站／服务分流候选、Diff、确认到草稿、撤销和完整副本导出；API Key 按 API 地址保存到 macOS 钥匙串，不回传其值。

2026-10-14 已按用户确认的 OpenCode 参考原型完成原生主对话＋按需审阅：宽窗口并排、窄窗口单区域，保留历史位置与每轮范围披露，旧候选只读，撤销受栈顶令牌保护。29 项 Swift Tests（VeerMac 15／VeerEditor 14）、Release 与 ad-hoc 签名通过；无节点／无密钥夹具完成浅深色、最小窗口和导出检查，非 rules 内容逐字保留。独立终审仅对本轮原生 UI 给出 ship。

后续已完成本机编辑服务内置：Node、生产依赖与 Mihomo 占位校验器打包进 `.app`，使用随机本机端口、stdin 认证握手和自有子进程生命周期，不再手动启动 4317。新增失败/超时重试与完整包启停测试；Web 46 项、Swift 32 项通过。独立目录原生导入、生成、确认、完整导出与退出重启已验证。详见 [内置服务记录](MACOS_BUNDLED_SERVICE_2026-10-14.md)。

真实 AI／订阅、VoiceOver、旧 OS、减少透明度、公开发行签名／公证未在本轮实测；Android 的既有改动作为开发快照同步，不宣称本轮重新验收。后续优先考虑会话持久化、真实 AI 流程验收与发行打包。

详情：[原生落地验收](MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md)、[原生运行说明](../native/macos/README.md)、[UI 改造计划](OPENCODE_UI_ADOPTION_PLAN_2026-10-14.md)。

## GitHub 同步与路径核对

同步目标为 `SpectreAX/veer-android` 的现有 `agent/ui-refactor-sync` 分支。同步前发现仓库公开，已按用户要求改为私有并通过 GitHub API 确认 `isPrivate=true`。不改写 Git 历史，不强推，不自动合并到 main。

当前实际 checkout 为 `/Users/spectreax/Developer/Veer`；`/Users/spectreax/Documents/Veer` 不是 Git 仓库。新版应用实际路径为 `/Users/spectreax/Developer/Veer/native/macos/dist/Veer AI Editor.app`，已核对可执行文件并在 Finder 中定位。GitHub 同步源码、测试与文档；`.app`、构建缓存、依赖与本机密钥不提交。

推送前复跑：Web 编辑服务 43 项、交互原型 5 项、Swift 29 项，合计 77 项通过；现有 `.app` 签名复核通过。暂存内容敏感模式扫描仅命中明确的合成日志脱敏夹具，未发现真实 Key、订阅 token 或私钥；本次同步包括 8 张无节点／无密钥原生验收截图。历史设备报告的 Markdown 换行和安装技能参考资料的 EOF 空行保留，不做无关格式改写。

---

## 总体进展

自 2026-07-29 项目分析以来，Veer 在两天内完成了 4 项 P0 级缺口修复（应用分流、自定义
DNS、实时日志、真机兼容性），随后在 07-31 启动第 1 轮体验优化功能开发，当日完成全部
3 项功能并通过构建门禁。第 2 轮的 AI 历史/模板、独立设置页和三档主题随后也已完成；
当前进入第 3 轮 i18n 迁移。

---

## 第 1 轮功能开发（07-31 完成）

### 功能一：活跃连接详情页

| 项目 | 详情 |
|:--|:--|
| 新建文件 | `ui/connections/ConnectionsActivity.kt` (283行)<br>`ui/connections/ConnectionsViewModel.kt` (251行) |
| 修改文件 | `core_mihomo/MihomoRepository.kt` — 新增 `ConnectionDetail` 数据类、`connectionDetails()` 解析 `/connections` 完整 JSON、`closeConnection()` / `closeAllConnections()` 调用 `DELETE /connections/{id}`<br>`AndroidManifest.xml` — 注册 ConnectionsActivity<br>`MainActivity.kt` — 首页新增"连接"快捷入口 |
| 功能 | 展示每个连接的目标域名/IP、命中规则、代理节点、协议、上下行流量、持续时间；支持搜索过滤（host/rule/chain）；三种排序（按流量/时长/域名）；关闭单个连接或批量关闭；每 2 秒自动刷新 |

### 功能二：首页实时流量图表

| 项目 | 详情 |
|:--|:--|
| 新建文件 | `ui/chart/SpeedChartCanvas.kt` (183行) |
| 修改文件 | `data/ConnectionStatusRepository.kt` — 新增 `SpeedSample` 数据类和 `speedHistory: StateFlow<List<SpeedSample>>`，60 秒环形缓冲<br>`MainActivity.kt` — ConnectionOverviewCard 下方集成 SpeedChart |
| 功能 | Compose Canvas 双线实时折线图（上传/下载）；Y 轴自动缩放；线下半透明渐变填充；速率格式化标注（KB/s、MB/s）；仅 VPN 运行时展示 |

### 功能三：节点体验优化

| 项目 | 详情 |
|:--|:--|
| 修改文件 | `ui/nodes/NodesViewModel.kt` (353行) — 新增 `NodeSortMode`（默认/延迟/名称/地区）、`NodeFilter`、`availableRegions`、`filteredGroups`<br>`ui/nodes/NodesActivity.kt` (448行) — 新增 `FilterRow`（FilterChip 排序/地区/可用性筛选栏）和 `DelayBadge` 颜色指示器 |
| 功能 | 按延迟/名称/地区排序；按地区标签筛选；隐藏不可用节点；延迟颜色分级（🟢≤100ms / 🟡100-300ms / 🔴>300ms或超时 / 灰色未测速） |

### 构建门禁

| 检查项 | 结果 |
|:--|:--|
| `testDebugUnitTest` | ✅ BUILD SUCCESSFUL |
| `lintDebug` | ✅ BUILD SUCCESSFUL |
| `assembleDebug` | ✅ BUILD SUCCESSFUL |

### 验收补充（已完成）

- [x] Android 16.1 arm64 模拟器端到端验证
- [x] `assembleRelease` R8 优化构建验证
- [x] 更新 `IMPLEMENTATION_STATUS.md` 记录新功能

---

## 历史里程碑回顾

### 07-28 ~ 07-30 已完成的 P0 缺口修复

| 功能 | 完成日期 | 状态 | 文档 |
|:--|:--|:--|:--|
| 应用分流 (Per-App Proxy) | 07-29 | ✅ 已通过 | `PER_APP_PROXY.md` |
| 真机 ROM 兼容性首轮验收 | 07-30 | ⚠️ HyperOS 通过 | `ROM_COMPATIBILITY_TEST_2026-07-30.md` |
| HyperOS 后台运行保护引导 | 07-30 | ⚠️ 实现通过，解锁 UI 待补 | `OEM_BACKGROUND_GUIDANCE.md` |
| 实时日志查看器 | 07-30 | ✅ 已通过 | `REALTIME_LOG_VIEWER.md` |
| 自定义 DNS 设置界面 | 07-30 | ✅ 已通过 | `CUSTOM_DNS_SETTINGS.md` |
| 物理设备生命周期加固 | 07-30 | ✅ 已通过 | 含在 IMPLEMENTATION_STATUS |

### 07-28 之前已完成的核心功能（15 项里程碑全部通过）

AI 规则隔离、运行中安全切换、LKG 回滚、AI 规则管理页、节点与策略组页、
连接状态主页、多操作 AI 计划、原子执行与回滚、本地解析、完整网络诊断、
自动恢复策略、定时刷新订阅、订阅信息与敏感数据安全、自动化测试矩阵（19/19）、
Release 发布加固与 ABI 分包。

---

## 与竞品差距变化追踪

| 缺口 | 07-29 状态 | 07-31 状态 |
|:--|:--|:--|
| 应用分流 | ❌ 缺失 | ✅ 已完成 |
| 自定义 DNS | ❌ 缺失 | ✅ 已完成 |
| 实时日志查看器 | ❌ 缺失 | ✅ 已完成 |
| 真机 ROM 兼容 | ❌ 未开始 | ⚠️ HyperOS 通过，扩展中 |
| 活跃连接详情 | ❌ 缺失 | ✅ 已完成并通过模拟器验收 |
| 流量图表 | ⚠️ 仅文本 | ✅ 已完成并通过模拟器验收 |
| 节点排序筛选 | ❌ 缺失 | ✅ 已完成并通过模拟器验收 |

---

## 下一步计划

### 第 2 轮功能（建议接续开发）

| 优先级 | 功能 | 预估 | 核心价值 |
|:--|:--|:--|:--|
| ⭐⭐⭐⭐⭐ | AI 操作历史 + 快捷模板 | 3 天 | 持久化 AI 指令历史，支持重新执行/撤销，空白时展示常用模板 |
| ⭐⭐⭐⭐ | 独立设置页面 | 2 天 | 集中管理 API Key、DNS、Per-App、后台保护、关于 |
| ⭐⭐⭐ | 深色模式手动切换 | 1 天 | 跟随系统/始终深色/始终浅色三档 |

状态：以上三项均已完成。详细验收见 `ROUND1_PROGRESS.md` 与
`NEXT_STAGE_DEVELOPMENT_PLAN.md`。

### 第 3 轮功能

| 功能 | 预估 | 核心价值 |
|:--|:--|:--|
| 字符串资源提取 (i18n) | 2 天 | 硬编码中文 → strings.xml，越早做迁移成本越低 |
| 导航架构统一（单 Activity） | 3-4 天 | 消除 Activity 切换白屏，统一 Compose Navigation |
| 规则管理增强（导入/导出） | 2 天 | AI 规则备份和迁移 |

### 第 3 轮当前进度：i18n Profile + DNS + Rules + Nodes（07-31）

状态：第一阶段及第二阶段 Profile、DNS、Rules、Nodes 切片已通过，整体迁移继续进行。

- 建立英文默认资源 `values/strings.xml` 与中文覆盖 `values-zh/strings.xml`，两侧各 150 个
  同名资源；`localeConfig` 声明支持 `en`、`zh`，Android 13+ 可使用系统应用语言设置。
- 已迁移主页、连接状态卡、VPN 启动进度、AI 快捷模板/历史、独立设置页、后台保护和全部
  Activity 标题。迁移范围内不再包含中文硬编码。
- 格式化文案统一使用带序号的 `%1$s` / `%2$d` 参数；Home、Startup、Settings 等纯状态
  模型改为资源 ID + 类型化参数，避免 ViewModel 在语言切换前提前拼接文案。
- 用户原始 prompt、profile/节点名、AI 执行结果、日志和 Mihomo 协议字段保持原样，不参与
  翻译，避免修改配置语义或历史证据。
- Profile 主列表、详情页及状态层已完成迁移。新增延迟解析的 `UiText`，激活、停止、启动、
  回滚和嵌套失败阶段均可随当前语言正确显示；英文/中文资源现各 230 个同名条目。
- DNS 页面与状态层已完成迁移；核心校验器改为 13 类类型化错误，不再持有展示语言，协议、
  端口、路径和凭据错误均由 UI 本地化。英文/中文资源现各 299 个同名条目。
- Rules 页面、状态层和展示模型已完成迁移；规则、域名、节点及 policy 原值保持不变，匹配
  范围、出口方向、健康状态和修改结果延迟本地化。英文/中文资源现各 347 个同名条目。
- Nodes 页面、状态层和延迟展示已完成迁移；节点/策略组名、地区代码、代理类型及延迟数值
  保持原样，筛选、测速和操作结果本地化。英文/中文资源现各 382 个同名条目。

验证：

- 175/175 Debug 单元测试，Lint、Debug、AndroidTest 和 R8 Release 构建通过。
- 新增中英文资源、格式参数、规则/节点展示和嵌套 `UiText` instrumentation；Android 16.1
  完整 runner `OK (27 tests)`，无跳过项。
- 模拟器通过 `LocaleManager` 在 `en-US` 与 `zh-CN` 间切换，主页、设置、Profile 和 DNS
  均通过对应语言回归；DNS 两种语言都完成自定义模式交互。
- HyperOS 真机保数据安装后双语资源专项 3/3 通过；未改动真实 DNS，VPN 已恢复
  `Running`。
- Rules 卡片与出口选择在模拟器英文/中文环境中均通过交互；HyperOS 双语资源和规则展示
  专项 4/4 通过，未修改真实 AI 规则，VPN 已恢复 `Running`。
- Nodes 筛选、延迟与隐藏不可用功能在模拟器英文/中文环境中均通过；HyperOS 双语资源和
  节点消息专项 5/5 通过，未切换真实节点，VPN 已恢复 `Running`。
- UI/状态层中文字符串由 438 降至 99；Profile、DNS、Rules 与 Nodes 当前为 0，剩余集中
  在 Per-App、Logs、Connections、辅助状态文件和旧 `VeerApp`。

详细迁移边界与下一批清单见 `I18N_MIGRATION.md`。

### 后续功能

| 功能 | 预估 | 说明 |
|:--|:--|:--|
| 订阅管理优化（到期预警/配额进度条） | 2 天 | 提升订阅管理效率 |
| Rule Provider 管理界面 | 3 天 | 高级用户强需求 |
| 简易配置覆写编辑器 | 3 天 | 高级用户"专家模式" |
| 流量统计历史 | 3-4 天 | 按日/周/月聚合流量趋势（需 Room 数据库） |
| 辅助功能 (Accessibility) | 1-2 天 | TalkBack 兼容 |
| GEO 数据库管理界面 | 1 天 | 设置页子项 |

### 并行推进（依赖硬件）

| 事项 | 依赖 |
|:--|:--|
| Pixel AOSP 基准验收 | 需 Pixel 实体设备 |
| ColorOS / OriginOS 兼容 | 需 OPPO/vivo 设备 |
| 8 小时锁屏功耗 soak 测试 | 需稳定网络环境 |
| x86_64 / armeabi-v7a 动态验收 | 需对应设备/模拟器 |

### 紧接下一项

继续 i18n 第二阶段：下一项为 Per-App，然后按 Logs → Connections
迁移剩余活跃页面；每页完成后执行资源一致性检查、单元测试和中英文 UI 回归。旧
`VeerApp` 在确认已无生产入口后删除或随单 Activity 导航迁移处理，避免翻译废弃界面。
