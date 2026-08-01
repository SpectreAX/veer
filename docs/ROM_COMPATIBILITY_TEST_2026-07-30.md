# Veer HyperOS 真机兼容性验收

测试日期：2026-07-29 至 2026-07-30  
结论：首台 HyperOS 真机核心链路通过；Pixel 和其它国产 ROM 仍需补充覆盖。

## 测试环境

| 项目 | 环境 |
|:--|:--|
| 设备 | Xiaomi Mi 10S |
| 系统 | HyperOS 1.0，Android 13（API 33） |
| ABI | arm64-v8a |
| 应用 | `com.yamax.veer` Debug + fault-injection AndroidTest |
| 核心 | Mihomo/Veercore，gomobile，gVisor TUN |
| 主机构建环境 | macOS，Homebrew JDK 21 |

本文不记录设备序列号、网络名称、出口地址、节点名称、订阅地址或凭据。

## 验收结果

| 场景 | 结果 | 说明 |
|:--|:--:|:--|
| 覆盖安装与数据保留 | 通过 | Debug 与 AndroidTest APK 均可覆盖安装，已有配置保持可用 |
| VPN/TUN 启动 | 通过 | 独立 Veercore 进程进入 `Running` |
| Mihomo Controller | 通过 | 本机 Controller 返回 HTTP 200 |
| 真实公网数据面 | 通过 | 经 Veer mixed port 请求 gstatic 与 Cloudflare 均返回 HTTP 204 |
| 停止后立即启动 | 通过 | 请求在安全 teardown 后排队启动；专项用例约 4.7 秒完成，无二次自动停止 |
| 服务内重连 | 通过 | 状态不再闪过错误的 `Stopped` 帧，重连回到 `Running` |
| 重启资源稳定性 | 通过 | 多批 Start/Stop 后 goroutine 数稳定，无按代际累积的 HTTP/TUN 协程 |
| UI/Core 进程隔离 | 通过 | UI 进程退出不终止隧道；Core 异常退出可按 desired state 恢复 |
| 锁屏/Doze 后台运行 | 通过 | 加入系统白名单并允许后台执行后，Controller 与数据面保持可用 |
| Wi-Fi 恢复 | 通过 | 底层网络恢复后 VPN 与公网探测恢复 |
| Per-App 三模式 | 通过 | 全应用、仅所选、绕过所选均能建立对应 UID 范围并保持联网 |
| 移动数据切换 | 未形成结论 | 本轮设备环境未提供可重复、可验证的蜂窝数据链路 |
| 首次授权与中文输入 UI | 未覆盖 | 设备测试期间处于锁屏状态，无法可靠操作系统授权页或输入法候选窗 |

## 自动化结果

真机 `LifecycleFaultTest` 全部通过：

```text
Tests run: 14
Failures: 0
Time: 53.639 s
```

覆盖范围包括：

- 五阶段真实启动进度；
- 并发 Start/Stop 串行化；
- teardown 期间晚到的网络回调；
- 多轮重启 goroutine 稳定性；
- 停止后立即启动排队；
- 自动恢复候选耗尽；
- JNI Start 挂起超时；
- Go panic 捕获；
- Error 状态信息；
- 服务内重连；
- 启动失败清理；
- JNI Stop 超时进入不可恢复状态。

同时通过：

```text
go test ./...
./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease
```

## 真机发现并完成的修复

### 1. Stop/Start 生命周期代际

`VeerVpnService` 现在用启动代际和 `stopSelfResult(startId)` 判定服务实例是否仍可
销毁。停止期间到达的新 START 会等待原生核心与 TUN 完整释放，再由同一服务实例
启动下一代运行时，避免旧 STOP 回调把新连接一并停止。

### 2. 原生执行器稳定性

Veercore JNI 调用统一进入稳定的单线程执行器。超时只改变 Android 状态机，不会
让后续调用越过仍在执行的原生操作，从而保持“任一时刻最多一个核心代际”的约束。

### 3. Mihomo 嵌入式清理

Stop 显式关闭 provider、tracker、代理适配器、TUN/listener、DoH client 和
resolver 连接。Android health-check 在取消后不再把整个不可达节点批次的剩余
超时转嫁给 Stop；所有原始 TCP dial 同时拥有硬超时。

### 4. URLTest 与 DoH HTTP 生命周期

- 节点 URLTest 改为单连接、同步 HTTP/1.1 HEAD，请求结束即关闭连接，不再创建
  会跨越核心代际的临时连接池。
- Android DoH 使用 request-scoped HTTP/1.1 连接，并在 Stop 永久关闭旧 resolver
  generation，消除了 `persistConn` 读写协程随重启累积的问题。

## HyperOS 特有观察

在该设备上，仅安装前台服务并不足以保证锁屏后的持续运行。测试所需系统侧条件为：

- 允许应用后台运行；
- 将应用置于 active standby bucket；
- 加入 Doze 白名单。

这些 ADB 设置用于验证核心能力，不应被视为最终用户流程。产品仍需增加 HyperOS/
MIUI 可见的“后台运行受限”检测、设置页深链和分步骤引导；不能尝试静默修改系统
白名单。

后续实现已在同日补齐：Veer 首页现在读取 Android 公开的电池优化、后台限制、
standby bucket 和省电模式，并在 Xiaomi 系设备显示“后台运行保护”卡片。
HyperOS 自启动和厂商省电策略没有公开读取 API，因此界面始终要求用户核对；
自启动、省电策略与应用详情入口已在本机成功解析。详细设计与边界见
`OEM_BACKGROUND_GUIDANCE.md`。

设备上的 `uiautomator` 无法在锁屏状态稳定获取窗口层级，因此本轮没有把首次 VPN
授权、通知授权、OEM 设置引导和中文输入法交互标记为通过。

## 剩余硬件门禁

1. Pixel 真机：AOSP 基准、锁屏 8 小时、Doze、Wi-Fi/蜂窝往返、系统回收。
2. 解锁本机及另一台较新 HyperOS/MIUI：验证新增后台限制引导可由普通用户完成，
   不依赖 ADB。
3. ColorOS/OriginOS：前台服务、自动启动、省电策略和任务清理行为。
4. 具备有效 SIM 的真机：Wi-Fi → 蜂窝 → Wi-Fi 连续切换与 DNS/UDP 回归。
5. 解锁设备：首次授权、通知、中文输入、Per-App UI 与无障碍人工验收。
