# Veer 本地 mixed-port 权限收紧计划

日期：2026-10-01
状态：步骤 1–4 已在模拟器验证；真机认证、DIRECT 正向流量与重连通过；代理出口仍待可用节点验收

## 问题与边界

Veer 在 Android 上固定开启 `127.0.0.1:7890` mixed-port。`allow-lan: false` 只限制监听地址，不区分 Android App UID；网络诊断、出口检测、自动恢复三个内部调用依赖它。此前 Controller 已迁至私有 Unix socket，但 mixed-port 是独立入口。本轮不改 TUN、节点或策略组逻辑，不触碰真实订阅。

目标内核：项目内 Mihomo v1.19.29 mirror（`go_core/third_party/mihomo`，当前 `cfd9c43`）；设备运行日志报告打包核心为 `veer-core/0.1.9+mihomo-1.19.29.e26714a.cmfa.gvisor`，两者 Commit 标记不同，因此源码判断还需以设备结果验证。平台：Android 36.1 arm64 模拟器，若真机在线再补真机。源码显示全局 `authentication` 应用于默认 mixed listener，`skip-auth-prefixes` 可绕过认证；不能把官方文档中回环地址的示例免认证段照搬到 Android。

## 步骤与验收

1. **复现暴露面。** 用独立 UID 的最小测试 App 向 `127.0.0.1:7890` 发无凭据 HTTP 代理请求；记录响应。若未能访问，仍继续静态核对配置，但不得声称已实测跨 App 漏洞。
2. **保护最终运行配置。** 在 `ConfigManager` 物化的配置中强制非空随机 `authentication`，明确清空 `skip-auth-prefixes`，覆盖订阅自带认证/免认证字段。沿用现有 app 私有、跨进程稳定密钥，不新增密钥生命周期。测试最终 YAML 的覆盖行为与 Mihomo 启动前校验。
3. **恢复内部调用。** 三个使用 `7890` 的 OkHttp 客户端共享一个带 Proxy Basic 认证的构造入口，保持原有超时；失败时不弹凭据窗、不泄露密钥到日志。
4. **设备回归。** 无凭据独立 App 得到 407/403；Veer 自身仍达到 Running、Controller available、Internet reachable，诊断和出口检测可用。覆盖 Stop→Start、Profile 切换、配置重新物化后的认证一致性。

## 回退条件

若目标 Mihomo 版本对本地 mixed listener 绕过认证，或内部探测因认证不稳定影响 VPN 健康判定，不留下“看似保护但实际开放”的配置；改为移除 mixed-port 依赖后关闭监听，并重新设计诊断探针。禁止以 `skip-auth-prefixes: 127.0.0.1/8` 作为永久修复。

## 证据约束

区分“监听于 loopback”“拒绝其他 UID”“成功代理流量”。仅凭 407 说明认证生效，不能证明端口不可连接；安全目标是未经授权不能使用代理。真机若未连接，报告只写模拟器结果。

## 验证记录

- 步骤 1（修复前）：Android 36.1 arm64 模拟器中，独立包名 `com.yamax.controllerprobe`（仅持 INTERNET 权限）向 `127.0.0.1:7890` 无凭据发送 HTTP CONNECT，收到 `HTTP/1.1 200 Connection established`。Veer 同时为 Running、Controller available、Internet reachable。说明当前 mixed-port 接受了其他 App 的无凭据隧道建立请求；本请求目标为关闭的测试端口，不声称已验证远端业务流量成功。
- 步骤 2：最终配置现在覆盖 `authentication` 为 `veer:<安装级随机密钥>`，并强制 `skip-auth-prefixes: []`；订阅中的其他用户/免认证段不能覆盖它。单元测试验证 YAML 覆盖；目标核心启动前配置校验和实际启动均通过。报告与测试输出不包含密钥。
- 步骤 3：`MihomoLocalProxy` 集中配置 OkHttp 的 loopback HTTP 代理和 Proxy Basic 认证，供出口检测、网络诊断、自动恢复三个调用使用。JVM 测试用 407 challenge 验证认证重试，`testDebugUnitTest` 与 arm64 Debug 构建通过。`MihomoMixedPortAuthInstrumentedTest` 设备端触发真实分层诊断与自动恢复健康探针，返回 `OK (1 test)`。第一次测试因 Instrumentation 停止目标进程导致等待既有 VPN 超时；测试改为自行启动 VPN 后通过，不计为产品失败。
- 步骤 4（修复后）：同一个独立 App、同一无凭据 CONNECT 得到 `HTTP/1.1 407 Proxy Authentication Required`；仅提供 SOCKS5 无认证方法的握手得到 `05 02`，即服务端要求用户名/密码而非接受无认证方法。Veer 状态页为 Running、Controller available、Internet reachable，出口身份可读取。快速重连后仍可达；Profile B→A→B 均可运行、联网，切到 A 后独立 App 仍得到 407。最终回到原活动 Profile B。

真机补测（M2102J2SC，Android 13，2026-10-01）：覆盖安装 arm64 Debug APK，保留原 Veer 数据、订阅和活动 Profile。独立 UID 测试 App 的无凭据 HTTP CONNECT 得到 407，SOCKS5 无认证握手得到 `05 02`；快速重连后重复测试，结果不变。内核回到 Running，活动 Profile 未改变，临时测试 App 已卸载。设备负向测试覆盖 HTTP CONNECT 与 SOCKS5 无认证握手；未独立验证错误密码和所有其他入站协议。

真机正向联网验收尚未通过：`MihomoMixedPortAuthInstrumentedTest` 两次在“机场出口”检查失败，第二次诊断为 `connection closed`。内核日志记录 Veer 自身的 `Auth success ... -> veer`，随后请求按 `DomainSuffix(gstatic.com)` 路由至当前策略组节点；因此已验证应用内部凭据被内核接受，但不能据此声称出口流量成功。同期节点健康检查大量返回不可用，部分日志为 `dns resolve failed: couldn't find ip`。需要单独核查该真机当前底层 DNS、订阅节点与出口连通性，再重跑完整诊断/自动恢复测试；不要把本次出口失败直接归因于认证改动。Instrumentation 会结束目标进程，测试后已重新启动 Veer 并确认 Running。

后续只读排查：Android Private DNS 为关闭，底层网络能访问国内 HTTPS；当前选中的 Trojan 节点服务器是 IPv4，真机 TCP 端口可连接，原始订阅和运行配置中该节点的 server/port/password/SNI/network 等字段逐项一致。订阅最近一次用量元数据获取于 2026-10-01 12:45（UTC+8），报告总额 360 GiB、已用约 360.047 GiB，超出约 48 MiB。这是节点拒绝转发的高概率外部原因，但单凭客户端元数据不能证明服务端实际拒绝原因。当前不修改订阅、不切换节点、不放宽认证；待配额恢复或提供有效订阅后重跑相同真机测试。测试断言已增加出口失败详情，构建通过。

独立正向验收：同一真机上新增一个不依赖机场节点的 Instrumentation 测试，Veer 内部使用带凭据的 mixed-port 客户端访问 `https://www.baidu.com/`，得到成功 HTTP 响应，`OK (1 test)`；内核流量日志确认 `DomainKeyword(baidu) using DIRECT`。这证明当前应用凭据、HTTP CONNECT、TLS 与 DIRECT 出站链路可用，不代表机场代理出口已恢复。测试后已重启 Veer 并确认 Running。

新订阅补测（不记录地址或 token）：2026-10-01 用户提供的 AnyTLS 订阅端点返回 HTTP 200、约 27 KiB，包含 32 个 AnyTLS 节点、20 个规则集、22 条规则与 2 条 `url-rewrite`。Veer 的完整导入被 `ConfigCompatibilityAudit` 拦下，原因包括 `rule-providers`、`url-rewrite`、策略组 `hidden` 和 `RULE-SET`；这是保护路由语义的预期拒绝，不应绕过审计或静默丢弃这些字段。目标 Mihomo v1.19.29 源码支持 AnyTLS，但 Veer 导入器原先未列入该协议；现已增加 AnyTLS 类型和必需密码校验，并通过相关 JVM 测试及 Debug 构建。

为隔离协议出口，真机以仅含订阅节点的临时配置做了单独烟测（不是完整订阅导入，也不是永久活动配置）。该配置可解析、启动并通过 Veer 的 mixed-port 认证，但首个节点的 AnyTLS 会话创建返回 `EOF`；逐一选择 32 个节点访问 gstatic，均未成功。节点共使用两个服务器 IP、同一端口和密码；Mac 同一网络对首个入口的直接 TLS 握手也失败。现有证据不能区分服务端状态、网络路径、凭据或目标核心兼容问题，不能宣称订阅出口可用。临时配置与设备侧 URL 暂存已删除，原 Profile 已恢复并重新 Running。要完成代理出口/自动恢复验收，需要一个在同网络其他 Mihomo 客户端中能访问 gstatic 的节点，或先解决这份订阅的服务端/网络兼容性；完整导入另需实现规则集等结构的保真支持。
