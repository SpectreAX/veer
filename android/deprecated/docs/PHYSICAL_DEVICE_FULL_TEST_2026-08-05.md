# Veer 真机全方位测试报告

> 2026-08-26 的 VPN 系统策略、Private DNS、Doze 与回归门禁增量结果见
> [PHYSICAL_DEVICE_SYSTEM_POLICY_TEST_2026-08-26.md](PHYSICAL_DEVICE_SYSTEM_POLICY_TEST_2026-08-26.md)。
> 该增量报告现已补充可用订阅恢复、真实 US/JP 出口、AI 路由、订阅刷新、约 1 秒
> 重连、快速停启竞态及最新 17/17 核心套件结果，应作为当前验收结论。

日期：2026-08-05  
设备：Xiaomi M2102J2SC，Android 13，HyperOS V816.0.4.0.TGACNXM  
应用：`com.yamax.veer` Debug，Mihomo v1.19.29，Go 1.26.5

## 结论

本轮完成核心生命周期、真实订阅、TUN 数据面、AI 规则、锁屏保活、IPv6、UI、
配置恢复和发布构建验证。最终核心套件 17/17 通过；测试期间发现的 DNS readiness
竞态、核心死亡观察空窗、sing-tun detach 泄漏、Gun HTTP/2 socket 泄漏和密钥
异步落盘问题均已修复并复测。

这不是“所有网络环境绝对可靠”的声明。蜂窝 INTERNET 在该设备上呈
`CAPTIVE_PORTAL`，因此 Wi-Fi↔蜂窝真实 handoff 无法形成有效对照；IPv6-only、
NAT64、Always-on/阻断无 VPN、数小时 Doze 和 VPN 权限撤销仍需专门环境。

## 测试矩阵

| 范围 | 结果 | 证据摘要 |
|---|---|---|
| 生命周期/故障注入 | PASS 17/17 | 66.328s；快速启停、重连、启动/停止超时、panic、核心进程崩溃恢复 |
| goroutine 稳定性 | PASS | 修复前 5 周期 +69；修复后单项与完整套件均通过 |
| DNS/TCP/UDP/规则 | PASS | Controller、DNS、HTTP/TCP、SOCKS5 UDP Associate 与 UDP DNS |
| 完整离线恢复 | PASS | Wi-Fi/数据关闭期间核心保持 Running；Wi-Fi 恢复后数据面 HEALTHY |
| 蜂窝 handoff | SKIP | 运营商数据网络为 CAPTIVE_PORTAL，未获得 VALIDATED INTERNET |
| 锁屏前台服务 | PASS | 熄屏 65 秒后主/核心 PID 稳定，Controller 与 SOCKS 仍为 200 |
| 通知权限 | PASS | 拒绝权限时核心可运行；允许后 FGS ID 1001、渠道 `veer_vpn` 可见 |
| IPv6 | PASS（常规双栈） | TUN ICMPv6 3/3；IPv6 字面量和 `ipv6.google.com` 经 SOCKS 均 HTTP 200 |
| 配置/订阅 | PASS | 真实订阅安全导入、激活，31 个源节点、3 个组、514 条规则 |
| UI | PASS 12/12 | Xiaomi 真机交互套件；另有多语言/顶层导航 6/6 |
| API Key | PASS | Android Keystore 加密；仪器退出、force-stop、覆盖安装后仍持久化 |
| Android 构建门禁 | PASS | Unit、Lint、Debug、AndroidTest、R8 Release |

## AI 路由实测

| Prompt | 计划来源 | 运行时结果 | 实际证据 |
|---|---|---|---|
| `ChatGPT go us` | LOCAL | `GEOSITE,openai,美国节点` | `chatgpt.com` 命中该规则，HTTP 200，Cloudflare LAX/US |
| `Netflix go hk` | LOCAL | `GEOSITE,netflix,香港节点` | `www.netflix.com` 命中香港节点，HTTP 302 |
| `ip.skk.moe go jp` | LOCAL | `DOMAIN-SUFFIX,ip.skk.moe,日本节点` | 命中日本节点，Cloudflare Ray 显示 NRT |
| `节点太卡了换一个` | LOCAL | Selector 切至实测 112ms 节点 | SOCKS HTTP 200，随后成功撤销至原选择 |
| `奈飞香港，油管美国` | LLM | 两条有明确出口的有序规则 | 历史来源 LLM，热更新成功 |

所有测试规则与 Selector 变更均通过 AI 历史撤销，最终没有遗留上述临时优先规则。
API Key、订阅 URL 和节点凭据未写入报告或测试日志。

## 关键缺陷与修复

1. Running 过早发布：加入 native tree + Controller 双证据 readiness gate，并在
   首帧前同步注入物理网络和 DNS。
2. Wi-Fi 切换空窗导致停核：网络丢失去抖，TUN/核心保留，underlying network 与
   system resolver 热更新。
3. 核心进程死亡 UI 不知情：AIDL `linkToDeath` + Provider 回退 + liveness poll。
4. sing-tun 重启泄漏：保留 `Attach(nil)` 的真实 detach 语义。
5. gRPC/Gun 泄漏：登记 live transport 和 raw socket；Stop 直接关闭活动 TLS
   socket，再清理 HTTP/2 pool。
6. API Key 偶发丢失：关键偏好写入由异步 apply 改为同步 commit。

## 与参考客户端的对照

- FlClash 的 Android service、VPN protect、延迟测试与网络观察方向支持“网络变化
  热更新、核心生命周期独立于 UI”的设计；Veer 使用 Kotlin/AIDL 与 gomobile 实现。
- Clash Verge Rev 的 service-mode 公开案例显示“核心仍转发但 UI 控制通道错误”
  和“旧核心未退出即启动新核心导致端口竞态”是不同故障层。Veer 因此同时验证
  数据面 readiness、Binder death、串行 Stop/Start 和端口/资源释放，避免只用 UI
  状态或单个进程存在性判断健康。

参考：

- https://github.com/chen08209/FlClash
- https://github.com/chen08209/FlClash/blob/main/CHANGELOG.md
- https://github.com/clash-verge-rev/clash-verge-rev
- https://github.com/clash-verge-rev/clash-verge-rev/issues/6741

## 测试后设备状态

- Veer VPN 已停止，主/核心进程已退出。
- Wi-Fi 与移动数据已恢复开启。
- POST_NOTIFICATIONS 与 MIUI AppOp 10021 已恢复为 `ignore`。
- 屏幕超时恢复为 60 秒，ADB 临时转发已清空。
- 订阅配置与加密 API Key 保留；临时明文文件已删除。
