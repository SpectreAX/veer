# Veer 真机系统策略与后台稳定性增量测试

日期：2026-08-26  
设备：Xiaomi M2102J2SC（thyme），Android 13，HyperOS V816.0.4.0.TGACNXM  
应用：`com.yamax.veer` Debug，版本 1（1.0）  
基线报告：[PHYSICAL_DEVICE_FULL_TEST_2026-08-05.md](PHYSICAL_DEVICE_FULL_TEST_2026-08-05.md)

## 结论

本轮补测 VPN 授权撤销、Always-on VPN、阻断无 VPN、Private DNS、强制 Light
Doze、资源稳定性，并在恢复可用订阅后完成真实代理出口、AI 路由、订阅刷新、快速
停启和重连回归。最终核心套件 17/17、UI 与本地化套件 19/19、Android 构建门禁和
Go 包检查均通过。

测试中修复了四类问题：调试规则可写不可删、调试刷新在核心进程错误初始化
WorkManager、订阅显示名泄露 URL 路径/查询参数、UI 进程重复同步同一 `Starting`
状态。可用订阅当前包含 33 个代理、3 个组、514 条规则；Controller、TUN 数据面和
区域出口均已用真实流量验证。受测试环境限制，本报告仍不声称覆盖 IPv6-only/NAT64、
可用蜂窝网络切换、8–12 小时后台运行或 Deep Doze。

## 测试结果

| 范围 | 结果 | 真机证据 |
|---|---|---|
| VPN 授权撤销 | PASS | `ACTIVATE_VPN=default` 后停止服务，再次启动被明确拒绝；Controller 不可达且没有假连接。恢复 `allow` 后服务、Controller 和 HTTPS 数据面恢复 |
| Always-on VPN | PASS | 系统设置写入 `com.yamax.veer`；VPN 已停止时重新启用 Always-on，1 秒内自动启动，Controller 持续 HTTP 200 |
| 阻断无 VPN | PASS | lockdown=1 且 Veer 停止后，设备裸 IP 与 DNS 请求均失败；重新启动后两者成功，SOCKS HTTPS 返回 204 |
| Private DNS 严格模式 | PARTIAL / RESILIENCE PASS | `dns.google` 的 IPv4 DoT 验证与经 Veer 的 TCP 853/UDP 443 流量成立；IPv6 DoT 超时后 HyperOS 自动回退至 off。全过程 VPN 保持 VALIDATED，Controller 200、HTTPS 204、系统 DNS 可用 |
| Private DNS 自动模式 | PASS / ROM FALLBACK | HyperOS 自动回退至 off；回退期间和之后 DNS、Controller 与 HTTPS 数据面均可用 |
| 强制 Light Doze | PASS | 锁屏、模拟断电并进入 Light `IDLE` 后持续约 5 分钟取 7 个样本；核心 PID 始终为 23171，Controller 全部 200，HTTPS 全部 204 |
| Deep Doze | BLOCKED BY ROM | HyperOS 始终报告运动状态 active / notMoving=false，`force-idle deep` 停在 `INACTIVE`；临时缩短 idle 常量仍无法进入，未将其误记为通过 |
| 资源增长 | PASS | 核心 FD 136 → 115，goroutine 67 → 48，核心 PSS 约 122 MB → 97 MB；主进程 FD 保持 93，无单调增长迹象 |
| 核心故障套件 | PASS 17/17 | 42.494 秒；覆盖启停竞态、超时、panic、核心崩溃恢复、无网络保活、DNS/TCP/UDP/规则和 goroutine 稳定性 |
| UI 与本地化 | PASS 19/19 | 26.331 秒；覆盖节点、规则、AI 历史、连接、DNS、设置、日志、导航、启动进度和 per-app 等界面 |
| Android 门禁 | PASS | `testDebugUnitTest`、`lintDebug`、`assembleDebug`、R8 `assembleRelease`；102 个任务，BUILD SUCCESSFUL |
| Go 包检查 | PASS | `go test ./...` 退出码 0；包当前无独立 Go test 文件，JNI 行为由核心真机套件覆盖 |
| 两段式规则清理 | PASS / FIXED | `MATCH,DIRECT` 可写入但旧删除入口要求至少三段而返回 false；新增按原始规则精确回退和单元测试。覆盖安装后真机返回 `removed=true runtimeReload=true`，规则文件与物化配置均为 0 命中 |
| 物理网络矩阵复测 | PASS + SKIP | opt-in 套件耗时 59.331 秒；完整离线区间保持 Running，Wi-Fi 恢复后数据面健康。蜂窝数据开启后 45 秒仍未出现 VALIDATED CELLULAR，handoff 用例按设计跳过 |
| 配置刷新失败安全 | PASS | 故意导入损坏 YAML 后返回 Failure，活动生成配置前后字节一致：`failed=true unchanged=true` |
| 日志导出脱敏 | PASS | 使用伪 API Key、Bearer 与订阅 URL 探针验证导出包，结果 `redacted=true`；未读取用户真实凭据 |
| 后台限制诊断 | PASS | 当前 HyperOS 正确报告 `ATTENTION/XIAOMI`、未被系统 backgroundRestricted；明确提示电池优化及 OEM 设置需人工复核 |
| 可用订阅恢复 | PASS | 通过设备端临时 secret 文件执行导入/激活，33 proxies、3 groups、514 rules；同一机制恢复 Keystore 加密 API Key；两个临时文件均自动删除 |
| 订阅即时刷新 | PASS | WorkManager 在 UI 进程排队；结果 `UNCHANGED`、无错误，生成配置哈希不变，运行中 HTTPS 数据面持续 204，无 crash/ANR |
| 订阅名称脱敏 | PASS / FIXED | URL 导入名称只使用 host；已有包含 URL、编码嵌套 URL、查询参数或异常长度的旧名称会迁移。真机迁移后名称安全，活动 ID、配置哈希和配置统计不变 |
| 订阅元数据节点过滤 | PASS / FIXED | `Traffic:`/`Expire:` 等配额行不再进入运行时组、区域识别或最低延迟候选；selector-heavy 配置的运行时条目由 91 正确降至 89 |
| AI `ChatGPT go us` | PASS | 本地解析为 `GEOSITE,openai,美国节点`，默认策略组保持不变；`chatgpt.com/cdn-cgi/trace` 返回 LAX/US；测试规则已删除 |
| AI `Netflix go jp` | PASS | 本地解析为 `GEOSITE,netflix,日本节点`，`www.netflix.com` HTTP 302；测试规则已删除 |
| AI 低延迟切换 | PASS | `节点太卡了换一个` 在真实 `千速云` Selector 内完成探测并切至 277 ms 可用节点，HTTPS 204；随后恢复为原自动选择 |
| 重连性能 | PASS | 真机数据面约 1023 ms 恢复，稳定 HTTPS 204，无 crash/ANR |
| 快速停止后立即启动 | PASS | 数据面约 1339 ms 恢复，5 秒后仍为 Running/204，无自动停止、crash 或 ANR |
| 重连状态去重 | PASS / FIXED | 首轮核心套件记录 `Stopping, Starting, Starting, Running`；`syncStatus` 改为只向观察者发布真实变化，重跑后 17/17 通过（40.531 秒） |
| 调试即时刷新进程 | PASS / FIXED | `REFRESH_SUBSCRIPTIONS` 从 `:veercore` receiver 移至主进程 receiver；广播排队与 worker 完成都不再触发 WorkManager 初始化崩溃或广播 ANR |

## 可用订阅与 AI 路由回归

最终保留在设备上的 profile 是用户提供的可刷新订阅，元数据为 33 个代理、3 个组、
514 条规则。Mihomo Controller 返回 HTTP 200，代理 HTTPS 数据面返回 204。测试期间
所有临时 AI 规则均通过原始规则精确删除，默认策略组恢复为自动选择。

| Prompt | 计划来源 | 运行时动作 | 数据面证据 |
|---|---|---|---|
| `ChatGPT go us` | LOCAL | 为 OpenAI geosite 增加明确美国节点出口；不改变通用 Selector | Cloudflare trace：LAX / US |
| `Netflix go jp` | LOCAL | 为 Netflix geosite 增加明确日本节点出口 | Netflix HTTPS 302 |
| `ip.skk.moe go jp` | LOCAL | 增加 domain-suffix 日本节点出口 | Cloudflare trace：NRT / JP |
| `节点太卡了换一个` | LOCAL | 在当前真实 Selector 中并发探测并选择低延迟节点 | 277 ms；切换后 HTTPS 204 |

此前 selector-heavy profile 还覆盖了 `OpenAI → US`、`Netflix → JP/HK` 等专用策略组
切换；专用组存在时优先切组，不存在时回退到 geosite + 具体节点。因此不会再把所有
服务指令无条件路由到通用机场组。

## OEM 自动化前提

HyperOS 会拦截由后台 instrumentation 进程启动的 Compose 宿主 Activity，并记录
`Abort background activity starts`。运行 UI 门禁时临时将 MIUI AppOp 10021 设置为
`allow` 后，原先挂起的同一用例在 2.566 秒内通过；完整 19 项套件随后一次通过。
这只是测试窗口权限，不是 Veer 生产运行权限。套件结束后已恢复为 `ignore`。

## 恢复与清理

- Always-on VPN 恢复为空，lockdown 恢复为 0。
- Private DNS 恢复为 off；VPN 授权恢复为 allow。
- AOD 恢复为 1；临时 `device_idle_constants` 已删除；battery 与 idle 模拟状态已重置。
- MIUI AppOp 10021 恢复为 `ignore`，移动数据恢复为测试前的关闭状态，Wi-Fi 保持开启。
- 临时 `MATCH,DIRECT`、OpenAI、Netflix 和测试域名规则均已删除；所有 Selector 已恢复。
- 最终验收后 Veer 保持 Running，Controller 200、HTTPS 数据面 204，便于继续调试。
- 未在报告、命令输出或仓库中写入订阅凭据、节点密钥或 AI API Key。

## 尚需专门环境验证

1. 提供可验证的蜂窝 INTERNET 后执行 Wi-Fi ↔ 蜂窝双向 handoff。
2. 在 IPv6-only/NAT64 网络执行 DNS64、IPv4 合成与 UDP/QUIC 数据面测试。
3. 在能进入 Deep Doze 的 AOSP/Pixel 设备执行 30 分钟以上深度空闲测试。
4. 执行 8–12 小时锁屏运行、周期性网络切换及资源曲线采样。此前长时监控由明确的
   `ACTION_STOP` 用户/设备操作终止，无 crash/ANR，但不能计为完整长稳通过。
