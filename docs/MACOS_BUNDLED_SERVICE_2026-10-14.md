# macOS 编辑服务内置计划

目标：启动 `.app` 即可导入、生成候选和导出，不要求用户安装 Node/Go 或启动终端服务。只打包编辑与规则校验能力，不启动 VPN、系统代理、TUN 或真实节点。

## 实施顺序与验收

1. 服务入口：复用现有服务，新增原生宿主入口。仅监听 127.0.0.1 随机端口；每次启动认证 token 从 stdin 传递，不放 argv、日志、配置文件。缺少/错误 token 拒绝请求；普通开发服务保持兼容。验证认证、非法握手、父进程退出、重启。
2. 原生生命周期：应用拥有唯一子进程，握手成功后注入 EditorClient；启动失败可重试，退出清理。通过 stdin EOF 处理父进程异常退出，不连接未知的既有 4317 服务。验证失败、超时、连续启停与会话不丢失。
3. 打包：复制当前自包含 Node、两个 npm 生产依赖、服务代码、Mihomo 本地 mirror 校验器和许可；排除密钥、用户配置、缓存、测试与 Web 原型。检查 Mach-O 依赖、架构、签名及打包后服务功能。当前首先提供本机构架开发包，不声称 universal/公证完成。
4. 验证与文档：复跑 Web/Swift 测试，将 `.app` 复制到含空格的独立目录，以受限 PATH 验证无需开发目录/外部服务。检查启动、导入、多服务预览、完整副本导出、退出与再次启动。真实 AI、旧 OS、公开签名/公证独立列为未验证项。

平台：macOS arm64；现有校验器版本 `veer-editor-local-mirror`，Go 1.27.1。本轮不改 Mihomo 源码或校验范围，仍只验证修改规则的占位出口，不代表完整配置或网络有效。已阅读项目 Mihomo 指南与其指定的 [OpenClash 用户指南](https://raw.githubusercontent.com/vernesong/OpenClash/dev/.github/skills/openclash-user-guide/SKILL.md)。

回滚：原来的手动 `npm start` 入口及可注入的测试 Client 保留。打包产物可重新构建，用户原配置不覆盖。

## 执行结果

- 已完成以上四项。Swift 的 `BundledEditorService` 统一拥有启动 Task、认证 Client、stdin/stdout 与子进程；并发调用复用启动，5 秒握手超时可重试；停止递增 generation 防止旧回调覆盖新服务。不在主线程阻塞等待进程退出。
- Node 宿主仅接受 64 位十六进制 token 握手，通过私有 stdout 返回协议号和随机端口；HTTP 在解析配置前验证 token，保留 Host/Origin/大小限制。父 stdin EOF、SIGTERM/SIGINT 均关闭连接并清理自有校验与钥匙串工具子进程；关闭期间不再产生新的工具进程。就绪行不含 token，生产错误不转发敏感诊断。
- 使用 Node 24.14.0 自包含运行时，arm64 slice，仅依赖系统 dylib，Mach-O 最低 OS 13.5（Veer 仍要求 macOS 14）；两个纯 JS 生产依赖 yaml 2.9.1 / diff 8.0.4。Mihomo `veer-editor-local-mirror` 校验器仅运行 `-t`；来源是本地仓库 mirror，不伪称官方发行核心。
- 打包仅复制 server/host/core、两个生产依赖、runtime 与校验器，不复制测试、public 页面、用户配置、Key、订阅、`.env`、整个开发缓存或原型。保留 [Node 24.14.0 许可](https://raw.githubusercontent.com/nodejs/node/v24.14.0/LICENSE)、两个 JS 包的许可证和 Mihomo GPLv3 文本。公开发行前仍需对应源码交付、完整依赖许可与签名/公证审查；本轮只是本机开发包。
- `.app` 约 164 MB：Node 113 MB、Mihomo 46 MB，其余为应用与生产依赖。构建检查 Node 外部 dylib、两项二进制架构，分别签名后复核整个 `.app`。独立 `.app` 不需要 Node/Go/npm 或源码目录；这些仍是从源码构建的开发依赖。

## 验证记录

- Web 服务 46 项 Node Tests 全通过：新增认证/错误来源、非法与超长握手、EOF 关闭和第二次启动、退出时终止正在校验的子进程与禁止竞争性新增进程。没有真实 Key、订阅或模型请求。
- Swift 32 项 Tests 全通过（VeerMac 15 / VeerEditor 17，其中启动失败/超时各一个参数化用例）：真实打包资源上的并发启动复用、导入/预览/占位校验/完整导出、幂等停止和旧端口不可达、重新启动；缺少资源、坏入口、5 秒超时与修复后重试。
- Release 构建与 `codesign --verify --deep --strict` 通过；旧 CommandLineTools 搜索目录有非阻断链接警告。
- 实际 `.app` 复制到 `/tmp/Veer Standalone Service Check 20261014.app`，独立 bundle ID；不重启用户另一个旧窗口。没有外部 4317 服务。原生夹具导入、Netflix→日本 / ChatGPT→美国 10 条候选、Mihomo 占位检查 passed、确认、完整副本导出成功。
- 导出操作使用系统保存面板；输入路径被面板转为文件名，验收生成的文件随后移到 `/tmp/veer-bundled-service-export-20261014.yaml`。YAML 解析与逐字比较证实 10 条目标规则＋MATCH，非 rules 内容不变，原夹具未覆盖。
- 首次服务进程只在 127.0.0.1:52176 监听；退出验收应用后宿主与 Node 进程、监听端口消失。再次打开仅空态（对话仍不持久化），新的自有服务在 127.0.0.1:52352 就绪；第二次退出也清理。没有修改系统代理、DNS、TUN 或用户密钥。
- 原生证据：`native/macos/artifacts/bundled-service-2026-10-14/standalone-local-export.png`。未重新评审视觉方向；write-swift 的主线程状态隔离和 ponytail 的复用现有服务/原生 Process 原则用于本轮生命周期与打包，未引入另一套规则实现或进程框架。

## 未验证与下一步

真实 AI API、真实订阅、实际钥匙串秘密读取、Intel、旧 macOS、VoiceOver、减少透明度和公开发行签名/公证未验证；此次不验证网络代理/TUN/DNS，因为应用不启动它们。同用户恶意进程读取进程内存或篡改开发 bundle 不在 loopback token 的保护范围内。

本轮只完成本机 arm64 包；universal/Intel、压缩与缩小 Node 运行时、会话持久化、公开发行准备可独立推进。当前内存草稿仍需退出前导出。
