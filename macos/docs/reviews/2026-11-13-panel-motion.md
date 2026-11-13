# 分栏动画修复与验收记录

2026-11-13，Codex；分支 `codex/macos-motion-profile`，基线产品代码 `main@0533e50`。以下为修复验收记录；源码已于后续交付步骤提交为6b2b6ff并推送到origin/codex/macos-motion-profile，没有替换实际应用或发布Release。

## 结论与实现

隔离样例中原先可见的概览卡片错帧重影、提问栏插入导致整页垂直跳变已在本轮抽帧中未再复现。独立复审 Critical0/Major0，保留一项滚动锚点Minor；呈现卡顿减少，仍未完全消除。

- [OverviewView.swift](../../Sources/VeerApp/OverviewView.swift)：`OverviewCardsLayout`在当前proposal内按原720/460页面断点排版，不再通过几何回调写宽度状态后切换AnyLayout。卡片身份保持；提问栏从卡片流顶部移至原生底部safeAreaInset保留区，面板打开时仍隐藏，不覆盖页面。
- [MainView.swift](../../Sources/VeerApp/MainView.swift)：配置名由原生Text在160/90pt内尾部截断，取消每次布局的逐字Core Text测量。完整名称保留在菜单、help和AX value。
- [ConnectionsTable.swift](../../Sources/VeerApp/ConnectionsTable.swift)：指标变化更新全量行缓存，仅刷新preparedContentRect∪visibleRect内必要列；结构、内容或行高变化仍走完整刷新，保留固定列、ID选择与滚动锚点。
- 测试覆盖真实子视图frame/不相交、断点及同宽内容改变、600唯一ID、UDP与非指标内容、可见/离屏/预加载缓存。没有更改原生分栏驱动、曲线、时长、版本号或lint基线。

## 测量与采样边界

运行环境：macOS27.3/26C5035r，Apple Silicon，SDK27.2，屏幕最大60Hz。交互样例为独立Bundle ID `com.yamax.veer.motionlab.baseline`、临时Store、binary=nil和拒绝代理的stub。没有真实内核启动、系统代理/TUN切换、AI发送或真实账户数据恢复。

性能输入通过Computer Use，1080×720外框、en/dark、6条唯一ID连接、示例策略组。概览服务处于合成加载状态；计时轮次没有截图或中途AX查询。正确性截帧独立运行。所有数值属于本轮样例。

最终采用较低开销的Animation Hitches+Points of Interest，每版20次开合，剔除前2次，匹配18次完整周期。按hitch起点归属；收尾窗口至Native AnimationEnd后100ms，上限下一次ToggleIntent。

| 版本 | 活动期事件/时长 | 含100ms收尾事件/时长 |
|---|---:|---:|
| 原始基线 | 42 / 700.00ms | 45 / 749.99ms |
| 同帧卡片+独立提问栏 | 25 / 416.66ms | 27 / 450.00ms |
| 再加入原生配置名截断 | 14 / 233.33ms | 14 / 233.33ms |

此单轮对照的完整操作窗口事件减少约69%，独立reviewer直接解析XML复算一致。它不代表固定FPS或所有页面/负载零卡顿。详细SwiftUI trace有额外开销，绝对计数不与此表混用；同一时段的详细四组对照18循环为：双空白0、空白正文/真实面板4、真实正文/空白面板29、双真实42，支持继续优先检查内容而非盲目重写分栏驱动。

CPU采样中profileName/shortened约250.8/239.8ms是同一路径的包含权重，不能相加。同步divider计时不等于FPS：004面板中位11.49/max52.54ms与同机基线11.40/max51.35ms接近；004边栏11.20/max23.12ms。连接600行500ms指标更新对照从8次full改8次partial，step中位7.64→6.95ms、max42.74→14.98ms；reload调用本身4.67→5.75ms，未声称每次局部刷新都更快。

曾尝试的独立高度动画、单宽度Layout.Cache、逐帧panelRevealFraction均无收益或退化，已完整撤回；其图和456项中间测试结果不是最终证据。最终没有这些实现。

## 实际执行的检查

- `bash .claude/scripts/verify.sh`：格式、strict lint、构建、454测试通过（UI20/Proxy111/Core294/App29）。最终日志 `native-title-final-verify.log`；不是凭Hook配置推断。
- 根快照脚本生成两轮当前源码隔离构建，独立reviewer实际打开52张inset相关图、40张最终标题相关图，共92张。两语言、两外观、概览/代理/连接、窄/标准面板/宽窗隐藏边栏、长Latin名，以及建议/停止/失败状态。16张无关TUN alert不计入审查。
- 场景请求的是内容尺寸860×560、1080×720、1440×900，PNG核对的外框分别为860×626、1080×786、1440×966。交互分析的标准外框为1080×720，最小被窗口约束为860×626。
- 最终标题动态20张窄窗和36张标准窗中独立查看12个关键帧，覆盖快速反向、460/720断点与边栏开合。作者另查看inset-standard9帧与CUA真实端点。
- CUA：原生配置菜单显示完整名称；Agent面板打开后焦点进入composer，关闭清至窗口；连接页CmdC→CmdF→CmdV、多选ShiftF10菜单、活跃指标更新后选择和滚动可用。
- Reduce Motion采用QA副本的独立布尔覆盖，没有改系统设置。面板2开关/3次position（一次额外位置校准）、0DriverStart；工具栏边栏2次操作/2次position。早期边栏快捷键读取真实environment，不能当作此覆盖的验证；随后已改走工具栏验证。
- 所有本轮交互测试副本已通过CUA退出。真实应用未被启动或替换。

## 独立审查

reviewer `motion_layout_review`只读审查源码、原始图与XML，没有代替作者重跑测试。最终无Critical/Major、新标题没有新增Minor。分类：

| 类别 | 结论与范围 |
|---|---|
| Window behavior | NOT VERIFIED：全屏、多显示器等 |
| Navigation/sidebar | PASS：所查看的概览开合范围 |
| Toolbar | PASS：已渲染范围 |
| Menu bar | NOT VERIFIED：完整菜单栏路径 |
| Native controls | PASS：源码/渲染范围 |
| Typography | PASS |
| Color/appearance | PASS：中英浅深矩阵 |
| Layout/resizing | PASS：保留下述Minor |
| Keyboard/focus | NOT VERIFIED：完整键盘路径；上文仅列实际做过的局部检查 |
| Accessibility | NOT VERIFIED：实际VoiceOver；AX名称属性已检查 |
| Error/empty/loading | PASS：已渲染状态范围，不含无profile全场景 |

保留 **MINOR / Risk**：在概览滚动到底部后反复开合面板，宽度重排和底部保留区变化会使滚动偏移（观察值1→0.709867），Groups需再次滚动才能看到；内容可访问，没有跳回顶部或操作阻断。这属于[Apple HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout)上下文连续性的体验细化，不是已确认的硬性禁令。后续可在过渡前确处于底部时于稳定后恢复bottom，其他位置保存可见卡片ID+偏移；避免新增逐帧状态。

仍NOT VERIFIED：macOS14 VM、真实VoiceOver、完整键盘流程、全屏/多屏、真实代理/TUN、最终版650节点压力场景、输入至首个可见像素延迟及长时统计性能。不能把基线650节点18.29ms中位数当作最终版结果。

## 本机证据与交接

忽略目录 `.codex/local/motion-20261113/` 保存：`native-title-final-verify.log`、`native-title-final-binary.json`、`lightweight-final-comparison.json`、三份`*-lightweight-actions.trace`及XML、`fresh-four-way-comparison.json`、`fresh-cpu-summary.json`、`frames-native-title-narrow/standard`和此前inset原始帧。

最终标题快照：`/var/folders/8b/9krhx4nn0bd2zz_0w21jj18c0000gn/T/veer-codex.fn2hWC/macos/dist/snapshots/2026-11-13-224712/`。
此前inset状态快照：`/var/folders/8b/9krhx4nn0bd2zz_0w21jj18c0000gn/T/veer-codex.Ljf6s4/macos/dist/snapshots/2026-11-13-165251/`。

详细规则与进度见根AGENTS.md、macos/CLAUDE.md、docs/WORKFLOW.md、docs/PLAN.md和`.codex/HANDOFF.md`。保留源码/证据，不以机器本地录制文件充当已提交的仓库资产。

## 构建与Git交付补记（2026-11-13）

用户随后明确要求构建、提交并推送。本次完整verify重新通过454项检查，delivery-verify.log保存结果；184个Swift源/测试文件与已审查快照完全一致，未重复执行视觉审查。

在隔离副本按原build-app.sh构建，得到Apple Development签名的1.0.6/build7开发应用，最低macOS14.0/SDK27.2。复制后deep strict签名检查通过，产物位于macos/dist/Veer-motion-profile-20261113.app；没有启动它或覆盖原dist/Veer.app。详情和校验值见根.codex/HANDOFF.md，未发布Release。

修复提交6b2b6fff7c56b14377eeedc8cf102a3a245c032c已推送，git ls-remote核对远端一致；交付文档随分支后续更新。上述Minor和NOT VERIFIED项目仍保留。
