# Veer Mihomo 核心运行逻辑审计

日期：2026-08-05  
状态：代码审计、Android 构建门禁与 HyperOS 真机核心专项回归完成；受运营商和系统策略限制的场景单独列出。

## 1. 审计范围与部署层级

本次审计严格按 `docs/MIHOMO_CORE_AGENT.md` 执行。Veer 不是 OpenWrt
透明代理，也不是桌面 sidecar；实际部署链路为：

```text
Compose/UI（主进程）
→ CoreStateClient（AIDL，ContentProvider 回退）
→ VeerVpnService（独立 :veercore 进程）
→ gomobile/JNI Veercore
→ Mihomo executor.ApplyConfig
→ Android VpnService TUN FD
→ gVisor TCP/UDP
→ 规则/策略组/代理或 DIRECT
```

因此没有照搬 OpenClash 的 dnsmasq、nftables、iptables 或 procd 逻辑。
OpenClash 只用于核对“启动前校验、就绪后发布、动态更新优先、逆序停止、
日志证据和回滚”等通用工程原则。

## 2. 权威版本与资料

- Mihomo tag：`v1.19.29`
- 上游 commit：`e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`
- tag commit 时间：2026-07-18T19:18:54+08:00
- Veer wrapper：`veer-core/0.1.9+mihomo-1.19.29.e26714a.cmfa.gvisor`
- gomobile tags：`cmfa,with_gvisor`；Debug 额外使用 `veer_fault_inject`
- Android API：最低 29
- 审计工作分支：`agent/ui-refactor-sync`
- 审计起点 Commit：`97a580206b940872052b8cc6219a49bb9bfcbdb0`

`go_core/go.mod` 的 `require v1.19.29` 通过 `replace` 指向本地 mirror。
将 mirror 与上游 tag 做文件级比对后，确认 `go.mod` 完全一致，Veer 差异是
明确记录的嵌入式生命周期补丁，不是未知 Alpha 快照。

强制前置 OpenClash 指南已完整读取；本次获取副本 SHA-256：
`f36032f8d44d164c5cade6e63930ff734f6b8b1013898ccb3ab01ab3b025dce4`。

参考资料：

- [Mihomo v1.19.29 源码](https://github.com/MetaCubeX/mihomo/tree/v1.19.29)
- [Mihomo executor.ApplyConfig / Shutdown](https://github.com/MetaCubeX/mihomo/blob/v1.19.29/hub/executor/executor.go)
- [Mihomo TUN 官方文档](https://wiki.metacubex.one/config/inbound/tun/)
- [Mihomo DNS 官方文档](https://wiki.metacubex.one/config/dns/)
- [FlClash Android NetworkObserveModule](https://github.com/chen08209/FlClash/blob/main/android/service/src/main/java/com/follow/clash/service/modules/NetworkObserveModule.kt)
- [Clash Verge Rev 核心 readiness 状态机](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/src/core/manager/state.rs)
- [OpenClash dev 源码](https://github.com/vernesong/OpenClash/tree/dev)

## 3. 审计发现与修复

### P0：默认 DNS 监听器绑定特权端口失败

证据：默认 asset 使用 `dns.listen: 0.0.0.0:53`，Android app UID 无权绑定
小于 1024 的端口，Logcat 明确出现 `bind: permission denied`。同时 Android
Builder 将 DNS 指向 Fake-IP 地址，错误容易表现为“VPN 已连接但无法上网”。

修复：删除本地 `:53` listener。Android 数据面由 TUN 的 `dns-hijack: any:53`
截获，DNS 请求进入 Mihomo 内部 resolver，无需进程对外监听特权端口。

验证：

- 上游 Mihomo `-t` 语义校验通过。
- Android 数据面测试中的 Mihomo DNS 查询通过。
- 修复后 Logcat 不再出现 DNS `permission denied`。

### P0：Start 返回不等于运行时就绪

旧逻辑在 `Veercore.start()` 返回后立即发布 `EngineState.Running`。Controller
或代理树尚未可用时，UI、AI 和配置切换事务会看到虚假的成功状态。

修复：新增有界 readiness gate。每次探测必须同时满足：

1. native 路由树已存在；
2. `127.0.0.1:9090/version` 在 200ms 限时内返回有效响应。

最多 10 次、间隔 100ms；失败进入 typed Error 并走唯一 teardown 路径；
Stop 在探测期间到达时取消发布 Running。

### P0：网络切换的瞬时空窗会销毁核心

旧逻辑在 `onLost()` 使网络集合暂时为空时立即 Error → Stop。Wi-Fi 与蜂窝
切换通常存在短空窗，因此这会把可恢复 handoff 变成长时间断开重连。

修复：

- 2 秒去抖，并取消已被新 `onAvailable()` 覆盖的 loss；
- 断网只更新连接状态，保留 TUN 与 Mihomo；
- `Network` 集合变化通过 `setUnderlyingNetworks()` 热更新；
- `LinkProperties.dnsServers` 去重后通过 gomobile 更新 Mihomo Android system
  resolver，并同步清理旧 resolver 连接；
- Stop 先关闭 monitor 事件入口，再进入 native teardown。

这与 FlClash 的网络/DNS动态更新方向一致，但 Veer 保留自己的独立进程、
readiness 和生命周期锁。

### P0：独立进程死亡没有可靠 Binder death 信号

旧控制面只使用 ContentProvider observer。Provider 进程死亡不会可靠触发
observer，UI 可能长期保留旧 Running。

修复：新增非导出、同 UID 的 `IVeercoreControl.aidl`：

- 主进程调用 `linkToDeath`；
- death 转为 `CORE_BINDER_DIED` / `RESTART_CORE`；
- 250ms 后重新绑定；
- 2 秒 liveness poll 作为厂商 ROM/Provider 回调遗漏的兜底；
- 新 PID 的 Stopped 快照触发既有串行恢复策略；
- ContentProvider 保留为有限、路径校验过的兼容回退。

### P0：停止超时与 late-start cleanup 存在责任竞态

旧逻辑让启动协程在释放 `engineMutex` 后等待 50ms，再判断停止协程是否已经设置
超时标志。慢设备上停止的 4 秒外层超时可能尚未发布，启动协程便认为“停止方会
清理”；随后停止方超时，又认为启动方会清理。结果是 native runtime 迟到完成后
无人执行第二次 Stop，排队的 Start 也永远停在 `Stopped`。

修复后只有实际观察到外层超时的停止协程能够创建 late-cleanup owner。它等待
启动释放互斥锁，执行唯一 native teardown，再原子领取排队启动。清理完成前状态
保持 `Stopping`，不再提前发布虚假的 `Stopped`；Stop 造成的已关闭 TUN fd 错误
也被识别为取消结果，不再伪装成第二个运行时故障。

### P1：停止态 UI 会无意义冷启动并保活核心进程

旧的 `CoreStateClient.init` 无条件绑定 `:veercore`，即使用户从未启动 VPN；核心
进程 `Application.onCreate` 又同步读取 Profile。冷模拟器曾因此超过 Android 的
ContentProvider 发布期限，系统连带杀死等待它的 UI 进程。

修复后：

- 仅在 durable desired-running marker 为 true 时建立 AIDL binding；
- Stopped 且不再期望运行时显式 unlink death recipient 并 unbind；
- 核心进程 Application 只初始化日志/状态发布，Profile 磁盘读取延后到前台服务
  已提升后的 IO 启动阶段；
- 冷启动 UI 实测只有主进程 PID，没有 `:veercore` PID 或 service binding。

### P1：EngineState 缺少可诊断元数据

新增由核心进程发布的 `EngineStatus`，包含：

- `timestampMs`
- `operationId`
- human-readable `message`
- machine-readable `machineCode`
- `rootCause`
- `recoverability`

启动、停止、重连、Profile 切换各自创建操作代际；AIDL/Provider 将原始元数据
同步到主进程，不在 UI 侧重新推测。

### P1：配置校验可被旧 AAR 静默跳过

旧 Kotlin 通过反射调用 `validateConfig`，方法不存在时只记录“skipped”并继续。
这违反“修改后必须由 Mihomo 语义校验”。现在直接调用版本化 gomobile API；
绑定不匹配会在构建期失败，运行时校验失败则在建立 TUN 之前终止。

### P2：正常 Controller 关闭被记录为 Error

上游 `http.Server.Serve` 在 `Close()` 后返回 `http.ErrServerClosed`。嵌入式
Stop 以前把它记录为 External controller error。Veer mirror 现在只忽略该预期
错误，其他 listen/serve 错误仍保留。

### P0：gRPC/Gun HTTP/2 传输跨重启代际泄漏

最终发布 AAR 在真实订阅（25 个 Trojan/gRPC 节点）上重跑时，5 次 Start/Stop 后
goroutine 从 23 增至 92。残留栈阻塞在 `http2clientConnReadLoop → TLS.Read`。
逐 Proxy `Close()` 和 HTTP pool `CloseHttp2Connections()` 已被调用，但活动 stream
不保证仍在 idle pool 内，因此底层 socket 没有释放。

修复：Gun 层登记所有 live transport 及其 raw connection；`Transport.Close()` 先
取消代际 context、直接关闭底层 socket，再清理 HTTP pool；Veer Stop 在关闭
provider/proxy 后调用全局 transport drain 作为最终屏障。修复后单项 5 次重启压力
和完整 17 项套件均通过，未再观察到跨代际增长。

### P1：API Key 异步保存可在进程立即退出时丢失

真机仪器测试曾在进程内成功读回密钥，但测试进程退出后加密偏好文件不存在。
原因是密钥写入使用 `SharedPreferences.apply()`，异步落盘尚未完成。密钥保存和
清除现改为同步 `commit`；已验证仪器进程结束、`force-stop` 和 APK 覆盖安装后
加密文件仍存在，明文临时文件已删除。

## 4. 生命周期与资源所有权

### Start

```text
operation id
→ materialize active config
→ attach logger/protector
→ ensure GEO DB
→ Mihomo semantic validation
→ establish Android TUN
→ dup TUN FD in Go
→ ApplyConfig
→ native tree + Controller readiness
→ start monitor/watchdog/recovery
→ Running
```

### Stop

```text
Stopping
→ coreRunning=false（禁止新 monitor 行为）
→ unregister ConnectivityManager callback
→ suspend tunnel / close TUN listeners
→ cancel providers and health checks
→ close trackers, proxy transports, DNS transports
→ executor.Shutdown
→ close external controller
→ detach logger
→ close JVM TUN FD
→ Stopped
```

Start/Stop/Reload 分别由 `engineMutex`、稳定 native executor 和 provider/AIDL
路径串行化。JNI Stop 超时保持 Error，禁止在可能 split-brain 的进程中直接重启。

## 5. 配置事务与回滚

现有 profile 路径已形成：Parse/Normalize → SnakeYAML Serialize → round-trip
Validate → atomic temp-file move → stop old runtime → activate candidate → readiness →
last-known-good commit。候选启动失败会停止失败代际、恢复 immutable LKG、启动并
再次等待 readiness，然后记录 rollback 结果。

本轮额外保证默认配置与运行时生成配置都必须通过 `Veercore.validateConfig`，不再
允许旧绑定跳过。AI 规则只热替换 rule table，避免完整 ApplyConfig 覆盖 Android
运行时注入的 TUN FD。

## 6. 已执行验证

| 验证 | 结果 |
|---|---|
| `go test ./...`（Veer wrapper） | PASS |
| patched Mihomo dialer/DNS/gun tests | PASS |
| Mihomo `-t` 默认配置语义校验 | PASS |
| Android Debug unit tests | PASS |
| Android lintDebug | PASS |
| readiness 双证据/超时/取消单元测试 | PASS |
| 网络 loss debounce 单元测试 | PASS |
| 快速 Start→Stop mutex 单项回归 | PASS |
| 断网保持 Running、native Stop 不增加 | PASS |
| `:veercore` panic→AIDL death→自动恢复 Running | PASS |
| Controller + DNS + MATCH rule + HTTP/TCP | PASS |
| SOCKS5 UDP Associate + UDP DNS response | PASS |
| release/debug AAR 重建与 Java API 检查 | PASS |
| 全量 Android instrumentation（36 项，743.29s） | PASS |
| 最终生命周期/故障类（17 项，含 unbind 后复测） | PASS（98.168s） |
| 停止态冷启动 UI 不创建 `:veercore` | PASS |
| Logcat 无 `:53 permission denied` / 正常 Controller 关闭误报 | PASS |
| HyperOS 真机生命周期/故障/数据面最终套件 | PASS（17/17，66.328s） |
| HyperOS 真机 UI 交互套件 | PASS（12/12） |
| 真机完整离线窗口 → Wi-Fi 恢复 | PASS |
| 真机锁屏 65 秒前台服务与数据面保活 | PASS |
| 真机 IPv6 TUN ICMP、SOCKS IPv6 TCP | PASS（3/3、HTTP 200） |
| AI 本地/LLM 规则、热更新、实际出口与撤销 | PASS |
| API Key 加密跨进程持久化 | PASS |

数据面测试不是只检查 REST API：HTTP 请求显式进入 `127.0.0.1:7890`，UDP 测试
完成 SOCKS5 UDP Associate，并通过 Mihomo 向外部 DNS 发送真实 UDP 查询。

全量 36 项回归覆盖本轮主要运行时改动。随后针对“停止态不应绑定核心进程”的
最终小改动，又完整执行了受影响的生命周期/故障类 17 项；因此没有把后一次局部
回归误写成“最终改动后再次执行了全量 36 项”。后续又在 Xiaomi M2102J2SC、
Android 13 / HyperOS `V816.0.4.0.TGACNXM` 完成真机专项；详细矩阵见
`docs/PHYSICAL_DEVICE_FULL_TEST_2026-08-05.md`。

关键产物 SHA-256：

- `app-debug.apk`：`6944698468531010643341a3398de061b940b129f4d0291a2835496c310c0b57`
- `app-release-unsigned.apk`：`3682a9226f1c6fcb1ef481664071a253827cc9e4af92e0b724945d5b0cb869a7`
- `libveer_core.aar`：`24439277f27cdbc00778d8fd5a3d58ce6de494fdae0111751ad4cb4c4741e994`
- `libveer_core_debug.aar`：`294777246d9aaf251d4e1d2fd0abef99313fda1e74786fd87ee7169de80b51f9`

主要复现命令：

```bash
cd go_core && go test ./...
cd go_core/third_party/mihomo && go test ./component/dialer ./dns ./transport/gun ./hub/route
./gradlew testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest assembleRelease
# 真机使用 am instrument 直接运行目标类；不要使用会卸载目标 APK 的 connected task
adb shell am instrument -w -r -e class com.yamax.veer.testing.LifecycleFaultTest \
  com.yamax.veer.test/androidx.test.runner.AndroidJUnitRunner
```

## 7. 回滚方式

本轮改动可按功能块回滚：

1. Kotlin readiness：`RuntimeReadinessVerifier` 与 `VERIFYING_RUNTIME` 调用点；
2. 网络热更新：`ConnectivityMonitor`、`SustainedNetworkLossDebouncer`、
   `UpdateSystemDNS`；
3. AIDL：`IVeercoreControl`、`CoreControlService` 与 `CoreStateClient` binding；
4. late-start：`launchLateStartCleanup`、队列领取及 truthful Stopping 语义；
5. 状态元数据：`EngineStatus` 与协议字段；
6. 默认 DNS：恢复 asset 行（不推荐，会恢复已证实的权限错误）；
7. Mihomo mirror：对照上游 commit 恢复单文件，再保留 `VEER_PATCH.md` 差异清单。

不应只回滚 AAR 而保留 Kotlin 新 API，或只回滚 Kotlin 而保留旧 AAR；二者必须作为
同一个绑定代际回滚。

## 8. 仍未验证，不能宣称完成的真机场景

下列场景需要有蜂窝网络/系统策略能力的物理设备，模拟器结果不能替代：

- Wi-Fi → 蜂窝、蜂窝 → Wi-Fi 的真实 radio handoff（本机运营商数据网为
  `CAPTIVE_PORTAL`，未获得可用 INTERNET/VALIDATED 网络，测试安全跳过）；
- IPv6-only / NAT64 和 IPv6 DNS 泄漏抓包；
- Android Private DNS 各模式；
- Always-on VPN 与 “Block connections without VPN”；
- Doze 数小时长稳与 OEM 主动回收；
- VPN 权限由系统设置页撤销；
- 大型真实订阅下的 FD、goroutine、内存长稳；
- 真机多应用 TUN 接管及 DNS/IPv6 泄漏抓包。

在这些项目完成前，可以声明“本机 HyperOS 核心逻辑、常规双栈数据面、短时锁屏
和断网恢复通过”，不能声明所有 Android 网络环境、运营商和 OEM 策略均已覆盖。

## 9. 本任务修改文件

Android 生命周期、IPC 与网络：

- `app/src/main/java/com/yamax/veer/VeerApplication.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/VeerVpnService.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/ConnectivityMonitor.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/RuntimeReadinessVerifier.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/SustainedNetworkLossDebouncer.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/MihomoEngine.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/MihomoRepository.kt`
- `app/src/main/java/com/yamax/veer/core_mihomo/ipc/*`
- `app/src/main/aidl/com/yamax/veer/core_mihomo/ipc/IVeercoreControl.aidl`
- `app/src/main/AndroidManifest.xml`
- `app/src/main/assets/base.yaml`

Go wrapper、Mihomo mirror 与绑定产物：

- `go_core/veer_core.go`
- `go_core/system_dns_android.go`
- `go_core/system_dns_stub.go`
- `go_core/third_party/mihomo/hub/route/server.go`
- `go_core/third_party/mihomo/transport/gun/gun.go`
- `go_core/third_party/mihomo/transport/gun/gun_lifecycle_test.go`
- `go_core/third_party/mihomo/VEER_PATCH.md`
- `go_core/third_party/sing-tun/*`
- `app/libs/libveer_core*.aar`
- `app/libs/libveer_core*-sources.jar`

测试、进度 UI 与契约文档：

- `app/src/androidTest/java/com/yamax/veer/testing/LifecycleFaultTest.kt`
- `app/src/androidTest/java/com/yamax/veer/testing/PhysicalNetworkHandoffTest.kt`
- `app/src/androidTest/java/com/yamax/veer/testing/SubscriptionImportPhysicalTest.kt`
- `app/src/androidTest/java/com/yamax/veer/testing/ApiKeyRestorePhysicalTest.kt`
- `app/src/androidTest/java/com/yamax/veer/testing/StartupProgressUiInstrumentedTest.kt`
- `app/src/test/java/com/yamax/veer/core_mihomo/*`
- `app/src/test/java/com/yamax/veer/core_mihomo/ipc/CoreStateProtocolTest.kt`
- `app/src/test/java/com/yamax/veer/ui/StartupProgressUiTest.kt`
- `app/src/main/java/com/yamax/veer/ui/StartupProgressUi.kt`
- `app/src/main/res/values*/strings.xml`
- `app/build.gradle.kts`
- `docs/runtime_invariants.md`
- `docs/process_isolation_architecture.md`
- `docs/native_runtime_contract.md`
- `docs/PHYSICAL_DEVICE_FULL_TEST_2026-08-05.md`

工作区中原有的 `AGENTS.md` 修改以及 `implementation_plan.md`、`task.md` 删除不属于
本任务，均未覆盖或恢复；本任务也未创建 Commit 或推送远端。
