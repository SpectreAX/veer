# CMFA 对照后 P0 改进实施报告

日期：2026-09-22
状态：两项 P0 代码、JVM、构建与模拟器验证完成；第二 App 独立隔离验证通过

## 范围

依据 `docs/CMFA_VEER_ARCHITECTURE_ANALYSIS_2026-09-22.md`，本轮只处理两项：

1. P0-A：导入订阅时，未支持的流量语义不得被静默丢弃。
2. P0-B：Mihomo 本地 Controller 必须鉴权。

不实现完整 Provider 系统、不重构配置模型、不改变 TUN / 进程生命周期。已有未提交文件保持原有修改；仅在必要位置作增量修改。

## 现状和风险

`ProfileParser → ClashYamlParser → RuntimeConfigGenerator` 只保留有限字段。原 YAML 的 `proxy-providers` / `rule-providers`、策略组 `use/filter`、DNS `nameserver-policy` 等可能在导入成功后消失；Mihomo 对**生成配置**的校验无法检测这种损失。另有无效规则被 `mapNotNull` 或 normalization 过滤的路径。对现有订阅，过度严格的审计会造成兼容性回退，所以必须区分 Veer 明确接管的字段和真正未支持的字段，并提供具体错误路径。

运行配置固定 `127.0.0.1:9090`，基础资产 `secret: ""`，REST 客户端默认空凭证。loopback 不是 Android App UID 边界。鉴权必须同时覆盖无 Profile 的基础配置、已导入 Profile、AI 规则重新物化配置和启动 readiness；否则会出现 VPN 可启动但 UI/AI 全部收到 401 的回归。

## 实施方案

### A. 配置能力审计

- 在导入解析前检查原始 YAML 结构；对会影响路由、DNS 或节点集合而当前模型不保留的键，返回专门的“未支持配置字段”错误，包含稳定的 YAML 路径，不泄露字段值/订阅 URL。
- Veer 接管的本地端口、Controller、TUN、sniffer、运行模式等顶层字段作为明确覆盖项处理；既有常见配置不能仅因这些键存在而被拒绝。
- 对策略组和 DNS 子字段做允许列表；拒绝 Provider 引用、未支持嵌套 DNS 策略及复杂规则选项。不得把未知规则静默过滤成 `MATCH,DIRECT`。
- 先以“明确拒绝”关闭语义损失，再在后续 P1-E 逐项支持 Provider；绝不直接透传外部监听器或脚本。

### B. Controller 认证

- 在 app 私有、不可备份目录生成一次 256-bit 随机 secret；跨 `:veercore` 与主进程并发读取使用文件锁与原子写，避免各进程生成不同凭证。
- `ConfigManager` 物化最终 `base.yaml` 时强制写入 secret；REST 仓库所有请求（包括 `/version` readiness）带 Bearer。不要将 secret 记录到日志或暴露在导出物里。
- 检查只有 `MihomoRepository` 消费 Controller 的生产路径；保留现有内部 REST API，不改变 Go bridge。

## 验收顺序

1. A：正常最小订阅通过；Provider、组 `use`、DNS policy、未支持规则明确拒绝；错误信息只有键路径，没有凭据；生成配置仍可通过既有 Mihomo 启动前校验。
2. B：同一安装的主/核心进程读到相同 secret；生成配置含非空 secret，Bearer 请求成功；无凭证请求 `/version` 和 `/proxies` 返回 401；重启后有效。
3. 回归：`testDebugUnitTest` 相关测试、`assembleDebug`；若设备在线，运行真机/模拟器启动与节点查询检查。若无法进行设备级安全复现，报告中明确标注未验证，不把代码检查称作运行结果。

## 回退条件

任一现有有效订阅被错误拒绝，应优先修正能力分类或提供明确兼容处理，不允许放松为静默丢弃。若鉴权导致 readiness 或 AI/节点控制失败，停止发布、保留无认证旧版对照构建供定位，不能在主分支留空密钥作为永久回退。

## 实施与验证记录

- A：新增 `ConfigCompatibilityAudit`，在正常解析前检查顶层、策略组、DNS 与规则的语义损失；无法保真的字段返回路径，不回显字段值。规则指向不存在的策略组/节点时也不再被 normalization 静默过滤。5 个定向测试通过。
- B：新增 `ControllerSecretStore`，用 256-bit 随机密钥、app 私有 `noBackupFilesDir`、文件锁和原子写保证主/核心进程读取同一值。最终物化配置强制绑定 `127.0.0.1:9090` 并写非空 secret；REST 仓库构造时拒绝空密钥，包括 readiness 探测在内的请求携带 Bearer。并发/持久化、配置覆盖、请求头测试通过。
- `./gradlew :app:testDebugUnitTest :app:assembleDebug --no-daemon`：通过。
- Android 36.1 arm64 模拟器：安装 Debug APK，导入项目自带 `valid_profile.yaml` 后 VPN 达到 `Running`，界面显示 Controller available、Internet reachable，路由为 `MATCH,DIRECT`。通过 ADB 转发以**无凭证**请求 `/version` 与 `/proxies`，均返回 HTTP 401。强制停止 App 后重新启动 VPN，Controller 与网络再次正常，`/version` 仍返回 401。
- 同一模拟器导入 `unsupported_provider_profile.yaml` 时，界面明确显示 `proxy-providers` 与 `proxy-groups[0].use`，原有 VPN 仍为 `Running` 且 Internet reachable。
- 2026-09-22 的 loopback 版本**未实测**独立第二 App 的访问、固定端口预占用和真实订阅/AI 指令；后续端口预占用验证见下节。

## 2026-10-01：修复固定端口预占用

Mihomo 当前 mirror 已支持 `external-controller-unix`。运行配置现在只提供位于 app 私有 `noBackupFilesDir/mihomo-auth/controller.sock` 的 Unix Controller，删除 TCP/TLS/Pipe Controller 字段；生产 `MihomoRepository` 通过 Android `LocalSocket` 与 OkHttp 的 socket factory 发送原有 HTTP 请求。目录明确设为 `0700`。不需要更改 Go AAR 或控制 API。上游 Unix 服务端在该路径不校验 Bearer（`hub/route/server.go` 的 `startUnix` 传入空 secret），**访问控制依赖 app 私有目录权限**；既有随机 secret 保留在配置里，但不应把它描述为 Unix socket 的鉴权机制。

验证：

- `./gradlew :app:testDebugUnitTest :app:assembleDebug -Pveer.abiSplits=true --no-daemon` 通过。模拟器空间不足以覆盖安装大型通用 APK，使用 122 MB 的 arm64 Debug 分包。
- Android 36.1 模拟器中用 `adb reverse tcp:9090 tcp:19090` 先占用 `9090`。Veer 仍达到 `Running`、Controller available、Internet reachable；节点页面成功读取 `GLOBAL` 与 `PROXY` 组，并将 `PROXY` 切换到 `DIRECT-TEST`，状态页仍显示 Running 和 Internet reachable；快速重连后也可访问网络。
- `no_backup/mihomo-auth` 实测权限 `drwx------`，socket 在目录内；非 app UID 的 ADB shell 读取该目录得到 `Permission denied`。撤销端口预占用后，`ss -lnt` 无 `9090` 监听（`7890` 是现有 mixed-port，不属于 Controller）。
- 强制停止 App 后重启，遗留 socket 文件被核心正常清理并重新监听，VPN 再次达到 `Running`、Controller available、Internet reachable。
- 安装独立测试 App `com.yamax.controllerprobe`（UID 10225），在 Veer（UID 10244）运行且 socket 确实存在时，用 Android `LocalSocket` 连接其绝对路径，得到 `IOException: Permission denied`。这验证了第二 App 不能越权连接；测试 APK 仅临时构建，未纳入项目。

`mixed-port: 7890` 仍是单独的本地代理入口，后续若要防止其他 App 使用，需要单独设计认证或移除依赖它的健康探测。
