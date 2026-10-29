# Veer for macOS：规格（2026-10-29）

本文规定每个页面和每项行为，需求见 [REQUIREMENTS.md](REQUIREMENTS.md)。“现有”指第 1 阶段已经提交的代码。

## 1. 架构

```text
Sources/
├── VeerCore/    配置模型、AI 编辑、校验、控制器客户端（来自 Editor，自行演进）
├── VeerUI/      设计令牌与组件；macOS 26 用 Liquid Glass，旧系统用标准材质
├── VeerProxy/   代理引擎，无界面、可测试
│   ├── ProfileStore    配置文件与订阅（现有）
│   ├── RoutingLayer    “我的分流”层：存储、重放、生成生效配置（新增）
│   ├── RuntimeConfig   在生效配置上写入 Veer 的端口、控制器、覆写和 TUN（扩展）
│   ├── CoreRunner      协议：用户进程（CoreProcess，现有）或后台服务（HelperCore，新增）
│   ├── SystemProxy     networksetup，开启前保存快照、关闭时恢复（扩展）
│   └── StateStore      state.json：上次的运行状态、系统代理快照
├── VeerHelper/  以 root 运行内核的后台服务（新增，第 4 步）
└── VeerApp/     SwiftUI 应用：主窗口、菜单栏、设置
```

- **最低系统：** macOS 14。`Package.swift` 用 `.macOS(.v14)`，`Info.plist` 的 `LSMinimumSystemVersion` 是 14.0。只在 macOS 26 上存在的接口，都包在 `VeerUI` 里用 `if #available(macOS 26, *)` 判断，页面代码不直接调用。

### 1.1 数据目录
`~/Library/Application Support/Veer/`：

| 路径 | 内容 |
|---|---|
| `profiles.json`、`profiles/<id>.yaml` | 配置文件索引，以及每份配置的原始内容（订阅下载下来的原样），现有 |
| `routing/<id>.json` | 这份配置的“我的分流”层 |
| `threads/<id>.json` | Agent 对话 |
| `core/` | 内核工作目录：`runtime.yaml`、geodata 缓存 |
| `state.json` | 上次的运行状态（是否运行、模式、系统代理、TUN）、系统代理快照 |
| `secrets.json`（0600） | 订阅链接和 API Key（开发版） |

- **用证书签名的版本：** 订阅链接和 API Key 存进钥匙串，服务名 `com.yamax.veer.secrets`。第一次启动时，如果发现 `secrets.json`，就把内容迁移进钥匙串，然后删除这个文件。
- **判断依据：** 签名里有 Team ID（`SecCodeCopySigningInformation`）就用钥匙串。测试阶段用的 Apple Development 证书和发布用的 Developer ID 都有 Team ID，签名身份稳定，重新编译后不会每次都弹出授权；只有 ad-hoc 签名的版本继续用文件。

## 2. “我的分流”层

### 2.1 内容
订阅内容原样保存，用户的改动都记在层里。每份配置一个层，内容如下：
- `edits`：按时间排列的修改记录。每条记录包含：
  - `id`、`createdAt`；
  - `source`（`agent`、`manual`、`healthCheck`、`template`）；
  - `prompt`：用户的原话，手动修改时是操作说明；
  - 现有 `EditReplay.Edit` 需要的字段：`plan`、`accepted`、`items`、`base`；
  - `enabled`：用户可以停用某条修改，而不删除它。
- `excludedNodes`：用户取消勾选的节点名称。
- `template`：选用的规则模板 id；为空表示用订阅自带的规则。

### 2.2 生效配置
生效配置 = `EditReplay`（原始内容，`template` 生成的规则 + 启用的 `edits`）→ 去掉 `excludedNodes` → 交给 `RuntimeConfig.build`。

- **去掉节点时：** 从 `proxies` 和所有策略组的 `proxies` 里删掉这些节点。如果某个策略组因此变空，就填入 `DIRECT`，并在配置页显示警告。
- **订阅更新后：** 重新计算生效配置，并把重放结果存起来。结果里有 `conflict` 时：
  - 在配置页和 Agent 页显示“N 条修改未能重放”；
  - 每条修改都能展开查看原因，可以选择让 AI 重新生成，或者停用这条修改；
  - 绝不悄悄删除修改。
- **撤销：** 撤销一条修改就是把它的 `enabled` 改为 `false`，然后重算。运行中的内核用 `PUT /configs` 立即生效。

### 2.3 导出
菜单“文件 → 导出配置…”。
- 导出合并后的生效配置，YAML 格式。
- 有一个选项“包含 Veer 的覆写（端口、DNS、TUN）”，默认关闭。关闭时导出的内容不经过 `RuntimeConfig`。
- 无论哪种，都不包含控制器地址和密钥。

## 3. 运行时配置（扩展 RuntimeConfig）

在现有项目（`mixed-port`、`allow-lan`、`log-level`、`external-controller`、`secret`，以及从配置里去掉的项目）的基础上，加入以下项目：

| 项目 | 规则 |
|---|---|
| `ipv6` | 设置中的值，默认关闭 |
| `find-process-mode` | 默认 `strict`；设置中可以改为 `off` |
| 禁用 QUIC | 打开时在规则最前面插入 `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` |
| `dns` | 配置里有 `dns` 段时沿用它，只补齐 TUN 需要的项。没有时写入默认值：fake-ip 模式、`fake-ip-filter`（`*.lan`、`*.local`、`+.push.apple.com`、`time.*.com`、`ntp.*`、`+.xboxlive.com`、`+.playstation.net`、`+.nintendo.net`）、DoH 上游（`https://dns.alidns.com/dns-query`、`https://doh.pub/dns-query`），`proxy-server-nameserver` 用相同的上游 |
| `dns.listen` | 不开 TUN 时去掉（现有行为）。开 TUN 时由 `dns-hijack` 处理，不监听 53 端口 |
| `tun` | 只在开启 TUN 时写入：`enable: true`、`stack: mixed`、`auto-route: true`、`auto-detect-interface: true`、`strict-route: true`、`dns-hijack: [any:53, tcp://any:53]`、`route-exclude-address`（`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`、`100.64.0.0/10`（含 Tailscale）、`fd7a:115c:a1e0::/48`、`fe80::/10`） |

## 4. 内核运行

- **CoreRunner 协议：** `start(config:onExit:)`、`stop()`、`tail`。
  - 不开 TUN 时用 `CoreProcess`（现有），以用户身份运行。
  - 开启 TUN 时用 `HelperCore`，通过 XPC 让后台服务以 root 身份运行。
- **切换配置、修改分流或覆写时：** 只要端口和 TUN 没变，就用 `PUT /configs` 重新载入，不重启进程；端口或 TUN 变了才重启。

### 4.1 后台服务（TUN）
- **注册：** 用 `SMAppService.daemon(plistName: "com.yamax.veer.helper.plist")`。可执行文件在 `Contents/Library/LaunchServices/VeerHelper`，plist 在 `Contents/Library/LaunchDaemons/`。
- **状态和界面：**

| 状态 | 界面 |
|---|---|
| `notRegistered` | TUN 开关旁显示“需要安装后台服务”，点击后注册 |
| `requiresApproval` | 说明需要去“系统设置 → 通用 → 登录项与扩展”批准，并提供按钮直接打开（`SMAppService.openSystemSettingsLoginItems()`） |
| `enabled` | 可以使用 TUN |
| `notFound` 或注册失败 | 显示原因，提示重新安装 Veer |

- **安全：**
  - **调用方校验：** 用代码签名要求校验调用方：同一个 Team ID，并且 bundle id 是 `com.yamax.veer`。macOS 13 起用 `NSXPCConnection.setCodeSigningRequirement`。
  - **能运行的程序：** 只运行 Veer 应用包内、通过同一签名校验的 `mihomo`，不接受任意路径。
  - **配置文件：** 以数据形式通过 XPC 传给后台服务，写进 `/Library/Application Support/Veer/core/`（属主 root，权限 0700）。控制器地址仍然是 127.0.0.1、随机端口、随机密钥。
- **生命周期：**
  - 应用断开连接（XPC invalidation）后等 10 秒，应用没重新连上，就停止内核。mihomo 退出时会自行清理路由。
  - 如果还有残留，后台服务删除 `utun` 相关路由。
- **失败回退：** 后台服务启动失败或崩溃时，改用用户进程运行内核并开启系统代理，同时显示“TUN 未能启动：原因”。

### 4.1.1 测试阶段的备用安装方式
测试阶段没有 Developer ID。如果 `SMAppService.daemon` 在这种签名下注册失败（指的是返回错误；`requiresApproval` 不算失败），TUN 页改为提供“手动安装后台服务”。签名里有 Developer ID 的版本不提供这个方式。

- **后台服务不变：** 和 4.1 是同一个 `VeerHelper`，XPC 接口、以 root 运行内核、断开后清理都不变，只是安装方式不同。
- **安装：** 点击后弹出一次系统的管理员密码框（`do shell script … with administrator privileges`）。脚本内容固定写在应用里，路径都加引号，不拼接任何用户输入。脚本做以下几件事：
  1. 复制 `VeerHelper` 到 `/Library/PrivilegedHelperTools/com.yamax.veer.helper`（root:wheel，0755）；
  2. 复制 `mihomo` 到 `/Library/PrivilegedHelperTools/com.yamax.veer.mihomo`（root:wheel，0755）。手动安装的后台服务只运行这份 root 拥有的副本，普通用户改不了它，所以不必再校验应用包里的 `mihomo`；
  3. 写入 `/Library/LaunchDaemons/com.yamax.veer.helper.plist`（root:wheel，0644），`MachServices` 是 `com.yamax.veer.helper`；
  4. 写入调用方校验要求 `/Library/Application Support/Veer/helper-requirement`（root:wheel，0644）；
  5. 执行 `launchctl bootstrap system` 加载服务。
- **调用方校验：** 后台服务从第 4 项的文件读取代码签名要求，用 `NSXPCConnection.setCodeSigningRequirement` 校验调用方：
  - Apple Development 签名：要求同一个 Team ID，并且 bundle id 是 `com.yamax.veer`。重新编译后仍然有效。
  - ad-hoc 签名：锁定安装时 Veer 的 cdhash。每次重新编译都会失效，Veer 发现连接被拒绝时，提示“后台服务需要重新安装”。
- **版本：** 后台服务通过 XPC 报告自己的版本和内核版本。和 Veer 不一致时，TUN 页提示“重新安装后台服务”（同样要输入一次密码）。
- **卸载：** TUN 页提供“卸载后台服务”：输入一次密码，执行 `launchctl bootout`，然后删除上面的文件。
- **改用 SMAppService：** 以后换成 Developer ID 签名、`SMAppService` 能用时，Veer 先卸载手动安装的版本，再按 4.1 注册。

### 4.2 系统代理
- **开启前保存快照：** 对每个已启用的网络服务，记下 web、secure web、socks 三种代理的开关、地址、端口，以及绕过列表，存进 `state.json`。
- **关闭时恢复：** 按快照逐项恢复，而不是一律关掉；用户原来自己设置的代理会回来。没有快照的服务，按现有行为只关掉指向 Veer 的代理。
- **启动时检查：** `state.json` 显示系统代理是 Veer 开的，但端口上没有进程在监听，就按快照恢复（扩展现有的 `recoverStaleSystemProxy`）。
- **网络变化和唤醒：** 用 `NWPathMonitor` 监听网络变化，并监听 `NSWorkspace.didWakeNotification`。两种情况下，如果系统代理开着，就给新出现的网络服务补设代理（同样先保存快照）。
- **和 TUN 同时开：** 可以。TUN 开着时，系统代理开关旁注明“已由 TUN 接管”。

### 4.3 启动与恢复
- **应用启动时：** 恢复 `state.json` 里上次的开关、模式、系统代理和 TUN 状态。现有的 `startCoreAtLaunch` 并入这一项：设置里叫“启动 Veer 时恢复上次的代理状态”，默认开启。
- **开机启动：** `SMAppService.mainApp`，默认关闭。

## 5. 主窗口

侧栏分两组，最下面是用户的配置名：

| 组 | 页面 |
|---|---|
| 代理 | 概览、代理、配置、连接、日志、请求（应做）、DNS（应做） |
| AI | Agent |

`⌘1` 到 `⌘8` 依次切换页面。工具栏中间是模式切换（规则、全局、直连），右边是启动和停止按钮（现有）。

### 5.1 首次使用引导
没有任何配置时，主窗口显示引导，不显示侧栏页面：
1. **添加订阅：** 可以粘贴链接、选择文件、从剪贴板导入，`clash://install-config` 链接会直接进入这一步。复用现有的 `ImportSheet` 逻辑。
2. **选择分流：** 两个选项，“保留订阅自带的规则”（默认）和“使用内置模板”（列出模板）。
3. **开启代理：** 一个大开关，同时启动内核并开启系统代理；下面一行写“可以随时在菜单栏关闭”。

AI 服务商不在引导里配置。

### 5.2 概览
- **状态卡：** 运行状态、当前配置、模式、运行时长。
- **速率卡：** 实时上传和下载速率，加上最近 60 秒的折线图。
- **流量卡：** 本次运行的上传和下载总量。
- **出口卡：** 出口 IP、国家或地区、运营商。
  - 只在内核运行且概览页可见时，通过代理端口请求 `https://api.ip.sb/geoip`，失败时改用 `https://ipinfo.io/json`。
  - 切换节点或模式后重新检测。
  - 设置里可以关闭（“检测出口 IP”）。
- **订阅卡：** 已用和剩余流量、到期时间，数据来自 `subscription-userinfo`（现有 `SubscriptionUsage`）。
- **建议卡（应做）：** 见 6.6。
- **出错时：** 内核启动失败时，概览顶部显示原因、最后几行日志和“重试”按钮（现有行为）。

### 5.3 代理
- **策略组卡片网格：** 每张卡片显示组名、类型、当前节点、成员数和测速按钮。点开后，节点以小卡片网格显示：名称、地区旗帜、延迟（颜色分为好、一般、差、超时）。
- **操作：** 只有选择型（Selector）策略组能点节点切换。整组测速用现有的 `testDelay`。
- **地图视图：** 用工具栏切换“网格 / 地图”。
  - 地图用随应用附带的 Natural Earth 110m 世界轮廓（公有领域），通过 Canvas 绘制。
  - 每个地区画一个点，颜色表示这个地区节点的最低延迟；点击后列出这个地区的节点。
- **节点地区：** 离线识别。先认旗帜 emoji，再按国家和城市的中英文名称、缩写匹配（扩展 `VeerCore` 已有的地区识别；可以参考塔台的识别表，用的话附上它的 MIT 许可证）。识别不出来的节点，可以在右键菜单里手动标记，手动标记存进“我的分流”层。

### 5.4 配置
- **列表：** 每份配置显示名称、类型（订阅或文件）、节点数、更新时间、流量和到期时间。
- **操作：** 切换（现有）、更新（现有）、重命名、删除、导出。
- **订阅自动更新：**
  - 间隔：有 `profile-update-interval` 就按它的值（单位小时），没有就 24 小时。
  - 先直连下载；失败时，如果内核在运行，再通过代理端口下载。
  - 失败时在这份配置上显示原因，不打扰用户。
- **节点勾选：** 详情里列出全部节点，每个都有勾选框，取消勾选就写入 `excludedNodes`。订阅更新后，勾选状态按节点名称保留。
- **“我的分流”列表：** 每条修改显示说明、来源和时间，可以停用、启用、删除或在 Agent 里查看。有重放冲突时置顶显示。
- **流量和到期提醒：** 剩余流量低于 10%，或者离到期不到 3 天时，发一次系统通知；每份配置、每种提醒只发一次。
- **配置诊断（应做）：** 复用 `ConfigHealthCheck`。问题列表中点任意一项，跳到对应的规则或策略组。

### 5.5 连接
- **刷新：** 页面可见时每秒请求一次 `/connections`；可以暂停。
- **表格列：** 主机（域名，没有域名时显示 IP）、进程、规则（类型和内容）、代理链、上传、下载、速率、持续时间。
- **操作：**
  - 搜索；按进程、策略组筛选；
  - 关闭单个连接（`DELETE /connections/:id`）、关闭全部；
  - 右键菜单：“问 AI”“为这个域名添加规则…”“复制主机”。“为这个域名添加规则”打开一个小表单（匹配方式、目标策略组），生成 `manual` 来源的修改。
- **路由地图（应做）：** 选中一条连接后，右侧显示“规则 → 策略组 → 节点”的路径图。

### 5.6 日志
- **数据：** 流式读取 `/logs?level=<设置的级别>`，保留最近 2000 条。
- **操作：** 按级别筛选、搜索、暂停、复制所选、清空。

### 5.7 请求（应做）
- 列出最近关闭的 1000 条连接：比较前后两次的连接快照，消失的就是已关闭。
- 只存在内存里，退出后清空。字段和连接页相同，另加关闭时间。

### 5.8 DNS（应做）
- 页面上提供一个查询框，调用控制器的 `/dns/query`，显示结果和耗时。
- 内核没有查询记录接口，所以不显示历史记录。

## 6. Agent

### 6.1 布局
- **左栏：** 对话列表（宽 240pt），按时间分组，可以搜索、删除；顶部有“新对话”（`⌘N`）。
- **右栏：** 对话内容，最大宽度 720pt，居中显示。
- **输入框：** 在底部，多行（回车发送，Shift + 回车换行）。旁边有执行模式选择器（默认“手动”）、模型选择器，以及附加的上下文标签（从其他页面带来的连接、规则或节点，可以移除）。
- **没有配置 AI 服务商时：** 右栏显示设置引导：选择服务商、填写 Key、测试连接。复用现有的 `AIProviders`。

### 6.2 对话
- 每个对话记住创建时的配置。用户切换到别的配置后，打开旧对话会提示“这个对话属于配置 X”，并提供“切换过去”按钮。
- 对话存在 `threads/<id>.json`，复用现有的 `Session` 和 `Turn` 模型并扩展。
- AI 的回复使用当前界面语言。

### 6.3 工具
| 工具 | 类别 | 是否需要确认 |
|---|---|---|
| 读取生效配置（匿名化） | 只读 | 否 |
| 最近连接、日志片段 | 只读 | 否 |
| 配置体检、域名命中排查、DNS 查询、规则集统计 | 只读 | 否 |
| 联网搜索 | 只读 | 否；只在用户的话需要时使用 |
| 修改规则或策略组 | 配置 | 按执行模式决定，默认要确认 |
| 切换节点、切换模式、测速、关闭连接 | 运行状态 | 否，执行后可以撤销 |

- **工具调用的显示：** 每次调用都显示为一行（图标、名称、简短结果），可以展开看详情。
- **“这次发送了什么”：** 每条用户消息下都有这个入口，展开后是发给 AI 的完整内容（匿名化之后的）。

### 6.4 运行状态操作
- **需要扩展：** 给 AI 的输出结构增加一类“运行状态操作”：
  - `select(group, node)`；
  - `selectFastest(group, region?)`：先测速，再选延迟最低的；
  - `mode(rule|global|direct)`；
  - `test(group)`；
  - `closeConnections(host)`。
- **执行：** 由确定性的代码解析和执行。节点和策略组的名称要先从匿名标签换回真实名称。
- **撤销：** 执行后，消息里显示结果和“撤销”按钮。撤销会恢复之前的节点或模式；关闭连接不能撤销，所以这一项不显示撤销按钮。

### 6.5 配置修改
- 复用现有的 `EditorEngine` 流程：计划、匿名化、校验、差异。
- **卡片：** 结果显示为差异卡片，列出每一项改动（可以单独取消勾选），按钮有“应用”和“放弃”。
- **应用后：**
  1. 写入“我的分流”层；
  2. 重算生效配置；
  3. 内核在运行时用 `PUT /configs` 立即生效；
  4. 卡片变成“已应用 · 撤销”。
- **执行模式：** 沿用现有的五种和 `writesAutomatically` 的规则。在 Veer 里，“写入草稿”就是“写入层并立即生效”。

### 6.6 解释路由
- **数据：** 用户问“为什么 X 这样走”，或者从连接页点“问 AI”时，附上以下内容：
  - 相关连接的域名、命中规则（控制器返回的 `rule` 和 `rulePayload`）、代理链；
  - `RuleMatcher` 在生效配置上的匹配结果，用来交叉验证。
- **回复：** AI 用简单的话解释，并在需要时附一张修正用的差异卡片。

### 6.7 主动建议（应做）
- **检测（全部在本机完成）：**
  - 同一个域名 5 分钟内在日志里出现 3 次以上连接失败；
  - 同一个域名 10 分钟内有 5 次以上连接命中 `MATCH`；
  - 当前选中的节点连续 2 次测速超时。
- **提示：** 在概览和 Agent 页显示卡片：“X 经常连接失败，要不要让它走 Y？”，按钮有“问 AI”和“不再提示这个域名”。
- **AI 调用：** 检测不调用 AI，只有用户点“问 AI”时才调用，并新建一个对话，带上相关数据。

## 7. 菜单栏
- **图标：** 内核没运行时显示灰色，运行中显示正常颜色；旁边可以显示实时速率（设置里可以关）。
- **菜单内容：**
  - 启动或停止；
  - 系统代理开关；
  - TUN 开关；
  - 模式；
  - 主策略组的当前节点（子菜单可以切换）；
  - 打开 Veer；
  - 退出。
- 没有 AI 输入框。

## 8. 设置
| 页 | 内容 |
|---|---|
| 通用 | 语言（跟随系统、简体中文、English；切换后重启 Veer 生效）、开机启动、启动时恢复上次状态、菜单栏显示速率、检测出口 IP |
| 代理 | 端口、允许局域网连接、IPv6、进程匹配、日志级别、禁用 QUIC |
| DNS | 模式（fake-ip、redir-host）、上游列表、“配置自带 DNS 时优先使用”（默认开） |
| TUN | 开关、后台服务状态和操作（见 4.1） |
| AI | 服务商、Key、模型、思考强度、执行模式默认值、联网搜索 |
| 快捷键 | 开关代理、切换模式、打开主窗口、新建 Agent 对话；默认都不绑定，点击后录制 |
| 关于 | 版本、检查更新、赞助链接、第三方许可证、导出诊断包 |

- **全局快捷键：** 用 Carbon 的 `RegisterEventHotKey` 实现，不引入第三方库。录制时如果和系统快捷键冲突，提示用户。

## 9. 国际化
- **文案存放：** 用 `.strings` 文件，放在 `Resources/Localization/zh-Hans.lproj` 和 `Resources/Localization/en.lproj`，打包时复制进应用包的 `Contents/Resources/`，运行时从主 bundle 读取。用 `.strings` 而不用 String Catalog，是因为本机只有 Command Line Tools，没有能编译 `.xcstrings` 的 `xcstringstool`。
- **键：** 用中文原文；插值写成格式说明符（字符串 `%@`，整数 `%lld`），端口这类不该加千位分隔符的数字先转成字符串。同一句中文在不同位置要不同译文时，用 `String(localized: "page.proxies", defaultValue: "代理")` 这样的独立键。
- **中文表：** `zh-Hans.lproj/Localizable.strings` 是空的，只为让系统把简体中文列为 Veer 支持的语言；查不到键时显示的就是中文原文。
- **测试：** `LocalizationTests` 扫描 `VeerApp`、`VeerProxy`、`VeerUI` 里的中文字面量（插值视为占位符），检查每一句在英文表里都有翻译，并检查译文的占位符数量和原文一致。
- **`VeerCore` 的提示：** 它的报错和说明（导入失败的原因等）暂时只有中文，第 2 步移植 Agent 时一并翻译。
- **语言切换：** 设置里切换语言时写入应用自己的 `AppleLanguages`，提示“重新打开 Veer 后生效”，并提供“立即重新打开”按钮（等当前进程退出、端口释放后再打开）。
- **不翻译的内容：** 规则内容、策略组名、节点名、日志原文。

## 10. 视觉
- **`VeerUI` 提供的组件：** `GlassCard`、`GlassButtonStyle`、`Toolbar` 背景等。macOS 26 上用 `glassEffect` 和 `.glass` / `.glassProminent` 按钮样式；macOS 14 和 15 上用 `.regularMaterial`、`.borderedProminent`，并加上圆角和描边。页面代码只用 `VeerUI` 的组件。
- **颜色：** 沿用现有的设计令牌，浅色和深色都要检查。延迟颜色：小于 200ms 为好，200 到 500ms 为一般，大于 500ms 为差，超时用红色。

## 11. 更新、备份与诊断
- **Sparkle 2：** 用 SPM 依赖。`SUFeedURL` 是 `https://github.com/SpectreAX/veer-releases/releases/latest/download/appcast.xml`；`SUPublicEDKey` 写在 Info.plist 里。每天检查一次，有更新时先问用户再安装。
- **备份（应做）：** “文件 → 备份…”导出一个 zip，包含 `profiles/`、`routing/`、`threads/`、设置（不含 API Key），订阅链接可选（默认不含）。恢复前显示将覆盖哪些内容，确认后再执行。
- **诊断包（应做）：** “关于 → 导出诊断包”生成一个 zip，包含最近的日志、匿名化后的生效配置、版本、系统版本、内核版本，不含任何密钥和订阅链接。导出前先预览内容。

## 12. 测试
- **单元测试：**
  - `RoutingLayer`：重放、冲突、去掉节点、导出；
  - `RuntimeConfig`：DNS、TUN、QUIC、IPv6；
  - `SystemProxy`：快照和恢复，用命令替身；
  - 运行状态操作的解析；
  - 主动建议的检测；
  - 两份 `.strings` 的键一致。
- **集成测试：** 用真实的 mihomo（设置 `VEER_MIHOMO_BIN`）测试启动、重新载入和关闭连接。
- **截图：** `SnapshotRunner`（现有）为每个页面、每种状态输出浅色和深色、中文和英文的截图。
