# CMFA 架构对照：Veer 当前改进项

日期：2026-09-22
性质：静态代码审查与设计建议；**未进行本轮真机性能或跨应用安全复现**。

## 1. 范围与结论

对照对象是 [Clash Meta for Android（CMFA）](https://github.com/MetaCubeX/ClashMetaForAndroid) 的固定提交 [`251a013`](https://github.com/MetaCubeX/ClashMetaForAndroid/tree/251a013b18f16c1077fcbad9dd7c855d8e1e97f4)，Veer 基线为本地 `cfd9c43`（`agent/ui-refactor-sync`）。本次 Veer 工作树已有未提交改动；下面的判断以审查时读到的文件为准，不能等同于发布版行为。Veer 使用本地 Mihomo `v1.19.29` mirror（`go_core/go.mod`），不是 CMFA 的二进制或生命周期实现。

**总判断：不应将 Veer 改写成 CMFA 的模块结构。** Veer 已有独立 `:veercore` 进程、AIDL 死亡感知、启动前 Mihomo 语义校验、readiness gate、网络切换去抖、Last Known Good 和 AI 事务回滚；这些不能因为 CMFA 的不同实现而删除。真正值得优先解决的是：导入转换可能改变订阅语义、loopback Controller 无认证、策略组选择跨配置相互污染，以及切换配置必须全量停启。

本报告遵循 `docs/MIHOMO_CORE_AGENT.md` 的层级边界：这里只比较 **Android VpnService + 嵌入式 Mihomo**，不把 OpenClash 的 OpenWrt 防火墙、dnsmasq 或 procd 做法直接套到 Android。`docs/MIHOMO_CORE_AUDIT.md` 的已修复项不重复列为待开发任务。

## 2. 架构与控制流对照

| 维度 | CMFA 的实现 | Veer 当前实现 | 判断 |
| --- | --- | --- | --- |
| 运行隔离 | `service` 模块把 `ClashService` / `TunService` 放在 `:background`；`ClashRuntime` 用互斥锁串行化运行时 | `VeerVpnService` 在 `:veercore`；主进程通过 AIDL / Provider 获取状态，`MihomoEngine` 管理启动停止 | 已具备隔离；保留 Veer 的 Binder death、状态代际和 readiness 设计 |
| VPN 数据面 | `TunModule` 将 Android `VpnService.Builder` 建立的 FD 交给核心，附带 socket protect / UID 查询 | Android 建立 TUN FD，Go wrapper + Mihomo + gVisor 处理流量，`tun.auto-route=false` | 同类模式；不需要改为 Linux 路由方案 |
| 配置导入 | `ProfileProcessor` 在 processing 区调用核心 `fetchAndValid`，随后供 `ConfigurationModule` 加载 | `ProfileParser` 解析为有限的 normalized model，再由 `RuntimeConfigGenerator` 重新生成 YAML；启动前 `Veercore.validateConfig` | Veer 的核心语义校验已存在，但发生在**转换之后**，无法发现原文件中被遗漏的能力 |
| 运行中配置切换 | `ConfigurationModule` 监听 Profile / Override 变化并调用 `Clash.load` | `ProfileRuntimeSwitchCoordinator` 对运行中的 Profile 执行 Stop → Activate → Start，失败则回滚 | 可评估热加载，但要先验证 Go runtime、TUN FD 和 DNS 的生命周期安全 |
| 策略组选择 | `ClashManager.patchSelector` 写入按 Profile UUID 索引的 `SelectionDao`，加载配置后恢复有效选择 | `MihomoRepository.selectProxy` 调用本地 REST；Mihomo 默认把选择写入**全局** cache | Veer 缺少应用层 Profile 级选择隔离；需先用复现测试量化 |
| 网络变化 | `NetworkObserveModule` 监听非 VPN 网络并通知核心 DNS 变化 | `ConnectivityMonitor` + 去抖 + underlying networks / DNS 更新 | Veer 已有对应能力；无需平移 CMFA 代码，只补真机网络切换回归 |
| Provider | `ClashManager` 提供 Provider 查询与更新 | 导入模型主要只保留静态 proxies / groups / rules；AI Provider 有局部热更新路径 | 订阅中的原生 `proxy-providers` / `rule-providers` 支持不完整 |

CMFA 证据：[运行时](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/clash/ClashRuntime.kt)、[VPN 服务](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/TunService.kt)、[配置模块](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/clash/module/ConfigurationModule.kt)、[Profile 处理](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/ProfileProcessor.kt)、[控制接口](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/ClashManager.kt)、[网络模块](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/251a013b18f16c1077fcbad9dd7c855d8e1e97f4/service/src/main/java/com/github/kr328/clash/service/clash/module/NetworkObserveModule.kt)。

## 3. 排序后的改进项

### P0-A：导入时不得静默丢失配置语义

**代码证据。** `ClashYamlParser.kt:68-72` 只解析 `proxies`、`proxy-groups`、`rules`、`dns`；`RuntimeConfigGenerator.kt:110-173` 从这些字段构造新配置，固定写入基础设施、TUN、sniffer 等字段。`ProfileValidator.kt` 只检验节点字段、组引用等，不检测未支持的顶层键。组解析仅保留 `name/type/proxies/url/interval/tolerance/strategy`；`use`、`filter` 等动态 Provider 相关字段不会进入生成文件。规则解析对复杂参数只专门保留第四项 `no-resolve`。原始配置即使 Mihomo 可用，转换结果也可能在缺规则、缺 Provider 或改变 DNS 行为后仍通过 YAML 回读和 Mihomo 校验。这是**语义保真问题**，不是语法校验缺失。

**影响。** 用户会看到“导入成功、VPN 已连接”，但实际分流与订阅提供者设定不一致。AI 随后基于错误的策略组/规则快照修改配置，问题会放大。

**最小可落地改法。** 第一阶段引入“能力审计”：解析原 YAML 时收集顶层键、组字段、规则类型，与当前生成器支持矩阵逐项对照；对影响流量决策的未支持项显示具体字段并**拒绝激活**，而不是静默降级。第二阶段按需求支持 `proxy-providers`、`rule-providers`、组 `use/filter`、DNS policy 等；保留未经授权的监听器、Controller、TUN、脚本等高风险项的明确覆盖/拒绝策略，不能简单把原 YAML 不加约束地透传。

**验收。** 用包含 `proxy-providers` / `rule-providers` / `RULE-SET` / `nameserver-policy` / 组 `use` 的小型固定样例：旧版会无提示丢字段；改版必须明确拒绝并指明字段，或成功导入且生成配置/实际路由保持一致。再做原始与生成配置的差异报告测试，避免只靠“能启动”判定成功。

### P0-B：收紧本地 Controller 权限边界

**代码证据。** 生成器写 `external-controller: 127.0.0.1:9090`（`RuntimeConfigGenerator.kt:115`），基础配置 `app/src/main/assets/base.yaml:17-18` 同样绑定 loopback 且 `secret: ""`；`MihomoRepository.kt:50,324,515` 默认无密钥，只有非空时才发 Bearer。所用 Mihomo 路由实现 `go_core/third_party/mihomo/hub/route/server.go:121-122` 在 secret 非空时才装认证中间件。

**风险界定。** `127.0.0.1` 只限制远端主机，并不天然构成 Android UID 级隔离；但本报告未通过第二个 App 实测可调用性，因此标为**高可信代码风险、待复现安全问题**，不宣称已被利用。

**最小可落地改法。** 每次安装生成并安全持久化随机 Controller secret，启动配置与 `MihomoRepository` 同步使用；基础配置和导入生成配置都覆盖到。不要把 secret 写进普通日志、诊断包或导出文件。若后续将所有操作收敛到非导出的 AIDL，可评估关闭 HTTP Controller，但不能破坏当前 AI、节点、日志和诊断路径。

**验收。** 另一个仅持 `INTERNET` 权限的测试 App 对 `127.0.0.1:9090/proxies`：无凭证为 401/403，Veer 本身正常查询和切换；重启后凭证仍有效或安全轮换；日志中没有密钥。

### P1-C：策略组选择按 Profile 隔离并恢复

**代码证据。** Veer `MihomoRepository.kt:392-414` 的选择操作只 PUT 到 `/proxies/{group}`，无 Profile ID；上游 Mihomo 默认 `StoreSelected=true`（`go_core/third_party/mihomo/component/profile/profile.go:7-8`），本地 REST 会写全局 `cachefile`（`go_core/third_party/mihomo/hub/route/proxies.go:98`）。CMFA `ClashManager.kt:49-58` 写入以 active Profile UUID 为键的 `SelectionDao`，`ConfigurationModule.kt` 在配置加载后恢复并清理无效选择。

**改法。** 保留 Mihomo cache，但新增小型 `ProfileId → group → selected` 存储；手动、AI、自动恢复路径共享一个写入入口。Profile 激活或重载后，只恢复仍属于当前组 members 的选择；组/节点被订阅更新删除时清理过期记录。避免仅以相同组名把 A 配置的美国节点应用到 B 配置。

**验收。** A、B 两个配置都含同名 `PROXIES` 组但成员不同：A 选节点 A1 → 切 B 选 B1 → 重启 → 切 A，应恢复 A1，B 应恢复 B1；删除 A1 后不尝试恢复失效成员。AI 和 UI 切换都覆盖。

### P1-D：先量化配置切换的停机成本，再决定是否引入热加载

**代码证据。** `ProfileRuntimeSwitchCoordinator.kt:82-153` 对运行中配置切换执行 Stop → Activate → Start，且配置激活接口在 runtime 未停止时拒绝（`ProfileManager.kt:246-250`）。CMFA `ConfigurationModule` 接收 Profile 变化并调用 `Clash.load`，没有相同的 UI 级全量 VPN 停启路径。

**改法。** 先在真机记录配置切换的 P50/P95 总耗时、TUN 中断时长、失败/回滚率，分别测小配置和含 Provider/GeoData 的配置。只有数据证明停机有明显影响，才给 Go wrapper 增加有界的候选配置校验和 `ApplyConfig` 热更新试验；先验证旧 TUN FD、socket protect、DNS、旧连接和网络监听器在新配置下的责任归属。保留现有 Stop/Start 路径作为失败兜底。不要直接将 CMFA 的 `Clash.load` 逐字映射到 Veer 的 Go 生命周期。

**验收。** 切换 20 次无双重 TUN、无泄漏、无错误节点残留；热更新失败时旧配置继续可用或在明确时间内回滚；与旧路径比较 P95 和连接中断时长。没有基准数据前，此项不宣称必然提速。

### P1-E：补齐原生 Provider 的生命周期，而不与 AI Provider 混淆

**代码证据。** 当前 Veer 有 `reloadAiProvider` / `reloadRules`，不等于原生订阅 `proxy-providers` 与 `rule-providers` 的导入、状态和更新能力。CMFA `ClashManager.kt:75-76` 暴露 `updateProvider(type, name)`。Veer 的解析/生成路径当前会遗漏这些订阅字段，故 Provider UI 不能先于 P0-A 独立上线。

**改法。** 以 P0-A 的能力审计为入口，再加入 Provider 定义保真、路径/URL 安全校验、更新状态/错误展示、手动更新；复用 Mihomo 已有 Provider 行为，避免在 Kotlin 侧重写调度器。AI 生成的本地 Provider 继续作为单独来源显示。

**验收。** 远程 Provider 初次导入、刷新、失败保留旧内容、网络恢复后重试、订阅 Profile 删除后清理，都有可观察状态；规则和节点 Provider 分开测试。

### P2-F：把现有保护机制变成可持续的质量门禁

Veer 已有 `Veercore.validateConfig` 在 TUN 建立前调用（`VeerVpnService.kt:347-365`）、readiness gate、Last Known Good、网络变化处理和 WorkManager 订阅刷新；这些不是“待补功能”。下一步应补固定回归矩阵：启动中 Stop→Start、连续 Profile 切换、Wi-Fi/蜂窝/无网络切换、订阅更新时连接仍在、AI 指令修改后真实出口验证、不同 ABI 构建。每个场景记录操作 ID、配置哈希、Profile ID、核心版本、TUN/Controller 状态及 P50/P95；脱敏后才能作为可比较性能数据。现有 `docs/MIHOMO_CORE_AUDIT.md` 与历史真机报告是历史证据，不能替代本轮复测。

## 4. 推荐执行顺序与每步验证

1. **先做 P0-A 能力审计与拒绝静默降级。** 只改导入错误呈现和判定，不同时重构整个配置模型。单元测试覆盖丢失字段、当前正常订阅和恶意监听器字段。
2. **做 P0-B Controller 认证。** 加入隔离 App 的负向安全测试，并回归所有本地 REST 消费者、AI 操作、启动 readiness。
3. **做 P1-C 选择隔离。** 使用双 Profile 真机/模拟器测试，尤其验证手动、AI、自动恢复三个写入口。
4. **在 P0-A 后做 P1-E Provider 支持。** 每补一种字段，都做原始/生成配置的语义对照与核心校验。
5. **测量 P1-D，再决定是否热加载。** 若旧路径已满足目标则不引入复杂生命周期分支；若超标，原型验证后分阶段替换。
6. **将 P2-F 并入 CI 和真机回归。** 只有稳定的性能和故障数据才可声称优于或接近 CMFA。

## 5. 明确不建议直接照搬的部分

- 不把 CMFA 的 `:background`、Room SelectionDao、AlarmManager 调度整套迁移到 Veer；只借其 **Profile 级选择隔离** 思路。Veer 已有进程隔离、存储与 WorkManager。
- 不用“保留全部原始 YAML”替代安全边界。订阅是外部输入，外部 Controller、监听器、TUN、脚本等须由 Veer 决定允许、覆盖或拒绝。
- 不把 CMFA 的代码结构等同于性能结论。两者 Mihomo 版本、Go wrapper、网络环境和机型不同；本报告没有可比的延迟、内存或耗电实测。

## 6. 本轮核查结果与限制

已静态核对本地解析器、生成器、Profile 激活路径、Controller 客户端、Go cache 行为和 CMFA 对应模块。没有改动应用代码，没有启动模拟器/真机，也没有对第二 App 验证 Controller；因此 P0-B 的实际可达性、P1-C 的跨 Profile 污染和 P1-D 的性能收益仍需按上述验收项实测。当前工作树已有其他未提交变更，本报告不将它们归因于本次分析。
