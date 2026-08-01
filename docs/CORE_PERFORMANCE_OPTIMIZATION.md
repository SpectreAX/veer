# Veer 核心性能差距与优化计划

更新日期：2026-07-29

## 1. 结论

Veer 的代理数据面使用 Mihomo 1.19.29，并启用了 Android 的 `cmfa`、gVisor TUN、`unified-delay`、`tcp-concurrent` 和 warning 日志级别。在核心版本、节点、配置、网络和设备完全一致的前提下，Veer 与 FlClash、ClashMetaForAndroid 的纯转发吞吐差距理论上不会像 UI 体验差距那么大，但目前没有完成同机 A/B，因此不能给出可信的 Mbps 百分比。

当前主要差距不在协议实现，而在客户端工程成熟度：

1. UI 与 Go 核心已完成进程隔离，但还缺少 release 真机和厂商 ROM 数据。
2. 已有启动、CPU、PSS/RSS 基准；吞吐、功耗和高并发基准仍待补齐。
3. Dashboard 已事件驱动化；核心 watchdog 仍保留必要的低频健康探测。
4. 大型订阅、连接列表、日志和批量测速仍需要持续做限流、增量更新和内存治理。
5. FlClash 和 ClashMetaForAndroid 已经过多轮 Android 主进程、VPN、Dashboard、延迟测试和进程隔离优化，长期设备/ROM 覆盖更广。

参考：

- [FlClash 变更记录](https://github.com/chen08209/FlClash/blob/main/CHANGELOG.md)
- [FlClash 核心桥接实现](https://github.com/chen08209/FlClash/blob/main/core/hub.go)
- [ClashMetaForAndroid 官方仓库](https://github.com/MetaCubeX/ClashMetaForAndroid)
- [Mihomo 通用配置文档](https://wiki.metacubex.one/config/general/)
- [Mihomo 流量统计管理器](https://github.com/MetaCubeX/mihomo/blob/Meta/tunnel/statistic/manager.go)

## 2. 2026-07-29 基线

环境：

- Android 16 arm64 模拟器
- Veer debug 构建
- 当前真实订阅和 TUN 代理
- 首页处于前台，状态刷新周期 5 秒

优化前一次首页状态刷新涉及的本地控制器响应：

| 接口 | 响应体 | 用途 |
|---|---:|---|
| `/version` | 33 B | 控制器可用性 |
| `/configs` | 1,512 B | 当前模式 |
| `/proxies` | 23,424 B | 当前策略、节点和延迟 |
| `/connections` | 3,057 B | 总流量和活动连接数 |
| 合计 | 28,026 B/轮 | 每 5 秒重复 |

额外问题：

- `/connections` 会为每个活动连接创建详情对象并执行 JSON 编解码，而首页只使用总上传、总下载和连接数量。
- 每轮互联网检测都执行 `connectionPool.evictAll()` 并发送 `Connection: close`，强制重复建立 TCP/TLS 连接。
- 出口地区缓存只有 10 秒，稳态下会频繁访问多个公网 IP/Geo 服务。
- 优化前单次内存采样为 137,209 KB PSS、209,128 KB RSS。该数值受 Go GC、gVisor、模拟器内存压力和采样时机影响，只作为 Veer 自身趋势基线，不能直接与竞品宣传数值比较。

## 3. 本轮已完成

### 3.1 原生轻量流量统计

新增 `Veercore.getTrafficStats()`：

- `statistic.DefaultManager.Total()` 直接读取原子累计值。
- `Range()` 只计数活动 tracker。
- 不再为首页请求、构造、传输和解析完整 `/connections` JSON。
- 保留 REST 回退路径，便于 Kotlin 源码与旧 AAR 临时混用。

### 3.2 原生轻量路由摘要

新增 `Veercore.getDashboardRoutingStats(defaultPolicy)`：

- 在 Go 进程内解析当前模式、主策略组、嵌套选择链、最终节点和最近延迟。
- 首页不再请求完整 `/configs` 与 `/proxies`。
- 节点管理、AI 决策等确实需要完整代理树的页面仍使用原接口。

稳态首页控制器 JSON 从 28,026 B/轮降到约 33 B/轮，减少约 99.88%。流量和路由数据改为 JNI 小对象读取。

### 3.3 连接与出口检测

- 稳态不再每 5 秒清空 OkHttp 连接池。
- 仅检测到“策略组 + 最终节点”变化时清理旧 tunnel，避免 HTTP/2 连接继续经过旧节点。
- 清理动作固定在 IO 调度器执行，避免主线程网络异常。
- 出口身份缓存从 10 秒延长至 60 秒，并绑定当前路由；节点变化立即失效。

### 3.4 批量测速限流

- AI 的“换一个延迟低的节点”最多并发 4 个延迟探测。
- 节点页的一键测速原本已使用 4 并发限制，保持不变。

## 4. 已完成验证

构建门禁：

- `go test ./...`：通过
- `./gradlew testDebugUnitTest assembleDebug lintDebug`：通过
- release/debug Mihomo AAR：均重新生成

运行验证：

- VPN 启动并保持 Running。
- Mihomo 控制器返回 200。
- `generate_204` 实际联网成功。
- UI 原生统计与 `/connections` 对照均为 5 个活动连接。
- 切换至 `🇯🇵日本 01` 后路由与出口显示 JP。
- 恢复 `🇭🇰香港 02` 后路由与出口显示 HK。
- 切换期间发现并修复一次 `NetworkOnMainThreadException`，修复后重复场景无崩溃。
- 稳定 30 秒后的单次采样为 156,120 KB PSS、230,744 KB RSS、进程 CPU 0.0%。这说明稳态无明显忙循环，但不能仅凭两次非受控采样宣称内存已经下降。

## 5. 与主流客户端的差距矩阵

| 维度 | Veer 当前状态 | 差距 | 优先级 |
|---|---|---|---|
| Mihomo 数据面 | 同版本 Mihomo、cmfa、gVisor，关键连接选项已开启 | 需要同机吞吐/功耗 A/B 才能定量 | P1 |
| 首页控制面 | 本轮已改为 JNI 轻量摘要 | 已接近 FlClash 的直接核心统计思路 | 已完成 P0 |
| 进程隔离 | VPN、TUN 和 Go 核心位于 `:veercore` | 待真机/ROM 验证后台限制 | 已完成 P1 |
| 功耗与唤醒 | 1 秒流量 IPC、事件路由、30 秒公网探测、后台暂停 | 待长时功耗/唤醒基准 | 已完成控制面 |
| 启动/重连 | 已有进度、串行状态机、超时和自动恢复 | 仍需真机 P50/P95 和 ROM 矩阵 | P1 |
| 大订阅 UI | 使用 LazyColumn；完整代理树按需读取 | 缺少代理树 diff、分页/版本缓存 | P2 |
| 延迟测试 | UI 和 AI 均限制为 4 并发 | 尚未合并重复目标和共享短期结果 | P2 |
| 内存治理 | 分进程 PSS、默认小内存 Geo loader、日志有上限 | 缺少 trim-memory 分级和 release heap 基准 | P1 |
| 可观测性 | 有日志、故障注入、运行状态 | 缺 Perfetto、Macrobenchmark、功耗和吞吐基准 | P1 |
| 长期兼容性 | Android 29+，已覆盖当前模拟器 | 真机、厂商 ROM、弱网和休眠覆盖不足 | P1 |

## 6. 后续执行顺序

### P1-A：建立可复现性能基准

先测量，再继续改核心参数。

状态：Veer 自身基线已完成，竞品同机适配器待实现。JSON/CSV runner、使用指南和
首份结果见：

- [PERFORMANCE_BENCHMARK_GUIDE.md](PERFORMANCE_BENCHMARK_GUIDE.md)
- [PERFORMANCE_BASELINE_2026-07-29.md](PERFORMANCE_BASELINE_2026-07-29.md)

测试矩阵：

- 同一台真机、同一 Mihomo 版本、同一 YAML、同一节点。
- Veer、FlClash、ClashMetaForAndroid 分别测试。
- TCP 单连接/多连接吞吐、UDP 吞吐、DNS P50/P95、首包时间。
- 1、10、100、500 活动连接下的 CPU、PSS、RSS 和丢包。
- 冷启动、热启动、断开、重连、切换配置的 P50/P95。
- 前台静置 15 分钟、后台静置 1 小时的唤醒次数和耗电。

验收输出：

- 原始结果保存为 CSV/JSON。
- 固定生成对比报告，不接受只看一次 `top` 或一次测速网站。
- 性能回归阈值进入 CI 或发布检查表。

### P1-B：核心进程隔离

状态：已完成（2026-07-29）。

VPN/Mihomo 已迁移到 `:veercore`；当前以显式服务 Intent 加非导出
ContentProvider 暴露：

- start、stop、restart、reloadRules
- engine state 和启动进度
- traffic/routing 小快照
- 日志批量流
- 健康检查和不可恢复状态

验收：

- UI 进程被杀后 VPN 不掉线。
- 核心异常退出可被检测并按预算恢复。
- 主进程与核心进程分别记录 PSS/RSS。
- 高频状态更新不得发送完整代理树。

### P1-C：事件驱动与前后台刷新策略

状态：已完成（2026-07-29）。

- 已完成：Dashboard 刷新只在 Activity `RESUMED` 时运行，后台 CPU 样本从
  1.596% 降到 0.299%。
- 已完成：引擎状态、节点切换、规则重载采用事件推送。
- 已完成：前台流量 1 秒读取原生计数，路由在启动、事件或 30 秒兜底时刷新。
- 已完成：公网可用性与出口探测调整为 30 秒。
- 已完成：Activity 不可见时暂停 Dashboard 刷新；VPN Service 仅保留低频健康检查。

验收：

- 首页稳态不再轮询 `/version`。
- 后台 15 分钟无 UI 定时任务。
- 节点切换后 2 秒内更新路由与出口。

### P2：大型配置与内存

- 为完整代理树增加版本号和短期缓存，多个消费者共享一次快照。
- 节点列表只在进入页面或核心事件变化时读取。
- 合并同名测速目标，复用 15–30 秒内的探测结果。
- 明确设置 `geodata-loader: memconservative`，并对 Geo 数据加载前后做 heap/PSS 记录。
- 在 `onTrimMemory` 中按等级清理 UI 图片、解析缓存和非必要历史，不能直接强制频繁 GC。

### P2：数据面专项调优

只有基准证明瓶颈后才修改：

- TUN MTU：比较 1500、3000、9000，关注蜂窝网络、QUIC 和分片。
- DNS：比较 fake-ip/redir-host、缓存命中率、IPv4/IPv6 和弱网回退。
- gVisor：测试高并发 TCP、UDP/QUIC、长连接和待机恢复。
- 节点协议：分别覆盖 Hysteria2、TUIC、WireGuard、VLESS、Trojan。

任何核心参数调整都必须同时验证吞吐、功耗、兼容性和断流率，不能只追求单次峰值。
