# Veer Android 性能基线：2026-07-29

## 环境

- Android 16 arm64 模拟器：`emulator-5554`
- Veer debug，Mihomo 1.19.29 cmfa + gVisor
- 当前真实订阅，香港节点
- 5 次 Stop/Start
- 稳态前预热 30 秒
- UI 返回桌面、VPN 保持 Running
- 3 次 `dumpsys meminfo` 取中位数
- CPU 窗口 10 秒，单核为 100%

原始结果：

- `build/perf/baseline-v2-2026-07-29/result.json`
- `build/perf/baseline-v2-2026-07-29/startup.csv`
- `build/perf/lifecycle-aware-2026-07-29/result.json`
- `build/perf/lifecycle-aware-2026-07-29/startup.csv`

`build/` 是本地生成目录；需要长期归档时应把 JSON/CSV 作为 CI artifact 保存。

## 首份可重复基线

| 指标 | 结果 |
|---|---:|
| Engine Running 中位数 | 302.378 ms |
| Engine Running P95 | 410.330 ms |
| 控制器可用中位数 | 312.210 ms |
| 控制器可用 P95 | 421.105 ms |
| 真实代理联网中位数 | 726.468 ms |
| 真实代理联网 P95 | 1,048.543 ms |
| 后台 PSS 中位数 | 209,452 KB |
| 后台 RSS 中位数 | 287,292 KB |
| 后台进程 CPU | 1.596% |

这里的启动结果是同一进程内的热重启数据。首次安装、首次进程启动、配置变化和
Geo 数据首次复制必须作为独立场景测量。

## 生命周期感知刷新优化

问题：主页 `LaunchedEffect` 只依赖 EngineState。Activity 进入后台时 Compose
composition 仍可能存活，因此首页每 5 秒的控制器、互联网和出口状态刷新会继续运行。

修改：

- AppState 改为 `collectAsStateWithLifecycle()`。
- Dashboard snapshot 循环放入 `repeatOnLifecycle(RESUMED)`。
- 后台立即取消刷新；回到前台立即执行新快照。

同样的后台稳态窗口：

| 指标 | 优化前 | 优化后 | 变化 |
|---|---:|---:|---:|
| 进程 CPU | 1.596% | 0.299% | -81.3% |
| PSS 中位数 | 209,452 KB | 212,957 KB | +1.7% |
| RSS 中位数 | 287,292 KB | 287,796 KB | +0.2% |

CPU 改善在本次窗口内明显。内存变化处于 debug/模拟器 PSS 波动范围，不能视为回归或
优化收益。

生命周期感知构建的启动样本包含安装后的冷态进程，不能直接与上一组全热态样本比较。
后续 runner 需要把 cold-process、warm-process、profile-switch 分为三个独立场景。

## 当前判断

1. 首页控制面和后台 UI 唤醒已从 P0 问题降为低频开销。
2. debug 模拟器后台 PSS 仍约 200 MB，是需要继续拆分测量的重点。
3. 下一步应增加 profileable release 真机基准，并分别报告 UI、Go runtime、gVisor、
   Geo 数据和连接 tracker 的内存。
4. 进程隔离已完成，下一步用 release/profileable 真机确认分进程结果。

## 进程隔离与事件驱动刷新基线

原始结果：

- `build/perf/process-isolation-final-2026-07-29/result.json`
- `build/perf/process-isolation-final-2026-07-29/startup.csv`
- `build/perf/process-isolation-foreground-2026-07-29/result.json`
- `build/perf/process-isolation-foreground-traffic-only-2026-07-29/result.json`

后台 5 次热启与 15 秒 CPU 窗口：

| 指标 | 结果 |
|---|---:|
| Engine Running 中位数 / P95 | 427.162 / 453.773 ms |
| 控制器可用中位数 / P95 | 436.753 / 462.969 ms |
| 真实代理联网中位数 / P95 | 760.219 / 898.912 ms |
| UI PSS | 90,587 KB |
| Veercore PSS | 125,756 KB |
| 合计 PSS | 216,326 KB |
| UI CPU | 0.000% |
| Veercore CPU | 0.332% |

前台 Dashboard 使用 1 秒流量、事件驱动路由与 30 秒公网探测。把 1 秒路径
从“流量 + 路由”进一步收窄为单次流量 IPC 后：

| 30 秒前台 CPU | 优化前 | 优化后 | 变化 |
|---|---:|---:|---:|
| UI | 0.565% | 0.499% | -11.7% |
| Veercore | 1.163% | 0.665% | -42.8% |
| 合计 | 1.728% | 1.164% | -32.6% |

两次前台 PSS 合计分别为 200,853 KB 和 210,583 KB，属于 debug 模拟器采样
波动，不能归因于此次控制面修改。跨进程 RSS 会重复计算共享代码映射，本报告只用
PSS 做总量判断。
