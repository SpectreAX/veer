## 第 1 轮功能开发任务清单

### 功能一：活跃连接详情页
- [x] `MihomoRepository` 新增 `getConnectionDetails()` 和 `closeConnection()` 方法
- [x] 新建 `ConnectionInfo` 数据类（完整连接信息）
- [x] 新建 `ui/connections/ConnectionsViewModel.kt`
- [x] 新建 `ui/connections/ConnectionsActivity.kt`（含 ConnectionsScreen / ConnectionRow）
- [x] `AndroidManifest.xml` 注册 ConnectionsActivity
- [x] `MainActivity.kt` 增加"连接"快捷入口
- [x] 单元测试（搜索/排序/关闭逻辑）

### 功能二：首页实时流量图表
- [x] `ConnectionStatusRepository` 增加 SpeedSample + 60s 环形缓冲
- [x] 新建 `ui/chart/SpeedChartCanvas.kt`
- [x] `MainActivity.kt` 集成 SpeedChart 到 ConnectionOverviewCard 下方

### 功能三：节点体验优化
- [x] `NodesViewModel` 增加排序策略 + 地区筛选 + 隐藏不可用
- [x] `NodesActivity` 增加 FilterRow + DelayBadge 颜色分级

### 回归验证
- [x] `testDebugUnitTest` 通过
- [x] `lintDebug` 通过
- [x] `assembleDebug` 通过
- [ ] 模拟器端到端验证

### 2026-07-31 验证记录

- 活跃连接定向单元测试 4/4 通过；全量 Debug 单元测试 135/135 通过。
- `lintDebug` 与 `assembleDebug` 通过。
- 真机 M2102J2SC（Android 13）覆盖安装成功；VPN、Mihomo 控制器和实际互联网均可用。
- 真机已验证：首页“连接”入口、连接详情、搜索空结果、排序菜单、后台/前台恢复。
- 未执行会影响现有网络会话的“全部断开”；单连接关闭和列表即时更新由单元测试覆盖。
- 模拟器专项验证仍保留未完成，待有模拟器在线后执行。

### 2026-07-31 首页实时流量图验证记录

- 新增 6 个采样/缓冲/格式化测试；全量 Debug 单元测试更新为 141/141 通过。
- 60 点和 60 秒双重窗口、纯下载流量、负值、长后台间隔及计数器重置边界均已覆盖。
- 真机通过 20 MB 下载产生实际流量，图表正确显示下载峰值及 60s/30s/现在刻度。
- 断开 VPN 后立即显示“未连接”并清空历史；重新启动不会显示旧会话峰值。
- 实时历史只在图表子树收集，仪表盘轮询状态不再触发 AI 设置和快捷入口区域重组。
- 120Hz 真机稳定采样期间无 missed-vsync、无 `Skipped frames`；整页 Debug 更新帧 CPU 中位数约 23ms、GPU 中位数约 6ms。Canvas 单独 `<2ms` 尚需 Macrobenchmark 独立测量。
- 验证结束后已恢复 VPN，Mihomo 控制器与实际互联网均可用。

### 2026-07-31 节点体验优化验证记录

- 新增 8 个筛选、排序和延迟展示测试；全量 Debug 单元测试更新为 149/149 通过。
- 地区筛选会移除无匹配节点的空策略组，地区代码匹配不区分大小写。
- 延迟排序顺序为：可用且已测速、未测速、不可用；名称排序不区分英文大小写。
- `DelayBadge` 覆盖未测速、≤100ms、101-300ms、>300ms、超时五种状态；`>=65535ms` 统一视为超时。
- 真机验证延迟升序结果为 97、98、99、105、106ms；JP 筛选后的可见节点全部标记为 `[JP]`。
- 真机一键测速完成 69 个节点：41 个可用、28 个超时或失败；没有执行节点切换。
- “隐藏不可用”开关的选中/取消状态正常；验证结束后已恢复“默认 / 全部 / 显示所有”。
- VPN 保持运行，节点页无崩溃。

### 2026-07-31 AI 核心可靠性优化

- [x] 含糊指令使用 `clarify`，不再强制生成配置修改
- [x] 未实现的 AI DNS 修改明确拒绝，不再返回假成功
- [x] 执行反馈基于真实提交结果并明确显示流量出口
- [x] 多服务同地区与多子句多地区指令本地解析
- [x] 服务直连/拦截和常用英文短指令本地解析
- [x] 无 API Key 时允许执行本地确定性指令
- [x] AI 专项单元测试与完整 Debug 门禁
- [x] 真机规则热重载与 `ip.skk.moe` 日/美出口切换验证
- [x] 删除全部临时 AI 规则并恢复运行态

### 2026-07-31 ChatGPT 美国出口不可访问

- [x] 复现并验证 OpenAI 规则已正确指向美国节点
- [x] AI 规则提交后定向关闭受影响的旧连接
- [x] 重复指令也刷新旧连接，避免“规则相同但会话仍走旧出口”
- [x] 定位 ChatGPT App `net_error -100` 为 DNS 污染导致的证书主机名不匹配
- [x] 明文 provider DNS 自动加固为 Cloudflare DoH
- [x] 加固时移除会重新引入污染结果的 fallback/filter
- [x] 更新自定义 DNS 推荐值并应用到当前真机配置
- [x] 真机验证 ChatGPT 主界面、历史会话与 TLS 日志
- [x] 全量 166 个单元测试、Lint、Debug APK 构建通过

### 2026-07-31 真机回归基础设施修复

- [x] 复现启动进度 Compose 测试在 Xiaomi 上无限等待
- [x] 四个 Compose UI 测试统一使用设备交互前置规则
- [x] 启动进度测试增加 10 秒硬超时
- [x] 确认 `connectedDebugAndroidTest` 会卸载共享真机目标包
- [x] 新增保数据 instrumentation 脚本，只卸载测试包
- [x] 真机 19 个测试条目正常完成，14 个生命周期用例全部实际执行通过
- [x] 重新导入活动订阅并恢复加密 DNS
- [x] 恢复 Netflix→日本、OpenAI→美国规则并重新验证联网

### 2026-07-31 ChatGPT 自建 DNS/DoH 路由补强

- [x] 抓取 ChatGPT App 真实连接链，确认 OpenAI 流量落入默认新加坡出口
- [x] 定位为 App 自建解析返回真实 IP，而运行配置未启用域名嗅探
- [x] 配置生成器默认启用 HTTP、TLS、QUIC hostname sniffing
- [x] 运行时物化再次注入 sniffer，兼容已有订阅配置
- [x] 新增配置生成与旧配置迁移回归测试
- [x] 真机验证 OpenAI API、ChatGPT 长连接和美国节点规则命中
- [x] 全量 167 个单元测试、Lint、APK 与 19 项真机测试通过

### 2026-07-31 第 2 轮：AI 操作历史与快捷模板

- [x] profile-scoped AI 历史持久化，限制 100 条且不保存凭据
- [x] 记录 prompt、LOCAL/LLM/SYSTEM 来源、结果和实际规则
- [x] 基于当前环境重新执行历史指令
- [x] 规则与 Selector 前后快照、安全冲突检查和补偿式撤销
- [x] 首页最近历史、再次执行、撤销状态和空输入快捷模板
- [x] 历史存储、容量、持久化、冲突策略与模板单元测试
- [x] 真机 DIRECT→REJECT 冲突拒绝及两级逆序撤销
- [x] 清理临时历史/规则并恢复原有 VPN 与 AI 路由
- [x] 171 个单元测试、Lint、Debug/AndroidTest、R8 Release 与 19 项真机回归
- [x] Android 16.1 arm64 模拟器端到端连接页、流量图、节点筛选与 AI 新界面验收
