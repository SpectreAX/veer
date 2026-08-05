# Veer 底栏信息架构

日期：2026-08-05

## 目标

按照 `AGENTS.md` 的清晰、安静、可靠原则，把高频功能归入稳定的 Material 3 底栏，减少首页重复入口，并保持二级任务的层级关系。

## 一级目的地

| Tab | 页面 | 归类内容 |
|---|---|---|
| 状态 | `MainActivity` | VPN 状态、启动进度、出口与流量、连接操作、AI 指令与历史 |
| 节点 | `NodesActivity` | 策略组、节点切换、批量测速、地区与延迟筛选 |
| 规则 | `RulesActivity` | AI 生成规则、流量出口、启用状态、改绑与删除 |
| 配置 | `ProfileActivity` | 订阅/YAML 导入、激活、刷新、配置详情与 DNS 入口 |
| 设置 | `SettingsActivity` | DNS、分应用代理、API Key、后台保护、主题与版本信息 |

首页“快捷操作”改为“诊断工具”，只保留活跃连接和实时日志；底栏已有的节点、规则、配置、设置入口不再重复。

## 层级与返回规则

- 一级页面始终显示底栏，不显示顶部返回箭头。
- 当前 Tab 不重复启动 Activity。
- 从首页进入其他 Tab 时保留首页作为返回栈根节点。
- Tab 之间切换时替换当前非首页页面，避免产生重复 Activity 栈。
- 系统返回从任意非首页 Tab 回到首页。
- 配置详情、DNS、分应用代理、活跃连接和日志等二级任务不显示底栏，继续使用顶部返回箭头。
- 配置列表进入配置详情时暂时隐藏底栏，返回列表后恢复。

## 视觉与可用性

- 使用 Material 3 `NavigationBar` / `NavigationBarItem`，最多五项。
- 图标与文字同时展示，选中态不只依赖颜色。
- 每个目标使用本地化标签和稳定语义测试标签。
- 覆盖 Light、Dark、320dp 窄屏、1.3 倍字体和长页面内容。

## 验收

- 共享底栏 Preview 与 Compose 交互测试。
- 五个一级页面截图确认选中态、内容不被底栏遮挡、无多余返回箭头。
- ADB 实际点击跨 Activity 验证导航与返回栈。
- JVM、Lint、Debug、AndroidTest、Release 构建以及全量设备测试通过。

## 验收结果

日期：2026-08-05

- 信息架构：`MainActivity`、`NodesActivity`、`RulesActivity`、`ProfileActivity`、`SettingsActivity` 共用同一个 `VeerBottomBar`；DNS、分应用代理、活跃连接、日志和配置详情没有接入底栏。
- 首页归类：移除节点、规则、配置、设置的重复快捷入口；“诊断工具”只保留活动连接与实时日志，AI 指令和历史继续归入状态页。
- 视觉：五个浅色一级页面、规则页深色模式及配置页窄屏大字体截图均通过目视检查；共享 Preview 明确覆盖 320dp 和 1.5 倍字体。
- 可访问性：五个项目始终显示图标和本地化文字，具有稳定测试标签；当前项同时使用语义选中状态和 Material 3 指示器。
- 返回栈：ADB 实际点击依次进入状态、节点、规则、配置、设置；切换后任务栈只保留状态页和当前 Tab；重复点击当前 Tab 不新增实例。
- 系统返回：验收中发现直接依赖系统 Activity 栈时可能从非首页 Tab 返回桌面，已改为共享 `VeerTopLevelBackHandler`；四个非首页 Tab 均通过直接启动后返回状态页的设备测试，配置详情仍优先返回配置列表。
- 自动化：`BottomNavigationUiInstrumentedTest` 覆盖五项展示、选中语义与点击分发；`TopLevelNavigationInstrumentedTest` 覆盖四个非首页 Tab 的系统返回行为。
- 发布检查：`testDebugUnitTest`、`lintDebug`、`assembleDebug`、`assembleDebugAndroidTest`、`assembleRelease`（R8）全部通过；标准模拟器全量设备测试 33/33 通过。
