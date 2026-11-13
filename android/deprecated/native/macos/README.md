# Veer macOS 原生 AI 编辑器

SwiftUI / AppKit 原生界面，无 WebView，不包含 VPN。最低 macOS 14，Swift 6.2+。当前本机 Swift 6.4 / Command Line Tools 可编译，不需要付费会员。

## 开发运行

构建前准备生产依赖和本机规则校验器（这是开发步骤，使用者无需执行）：

```sh
cd /Users/spectreax/Developer/Veer/prototype/ai-editor
npm ci
npm run build:validator
```

已有 `.cache/mihomo` 时不必重新构建校验器。然后：

```sh
cd /Users/spectreax/Developer/Veer/native/macos
node scripts/test-native.mjs
zsh scripts/build-app.sh
open "dist/Veer AI Editor.app"
```

`.app` 现已内置 Node 24.14.0、生产依赖、编辑服务与 Mihomo 规则校验器；双击即可运行，不再需要 `npm start`，也不依赖开发目录。启动时仅监听 127.0.0.1 的随机端口，用每次启动的认证 token 隔离请求；token 经 stdin 传递，不进入命令行、文件或日志。退出应用会关闭自有服务；父进程异常退出时 stdin EOF 也触发清理。不会连接既有 4317 服务，不会修改系统代理。

可以用 Xcode 打开 `Package.swift` 阅读/测试源码，但应用调试必须使用带 Resources 的 `.app` 构建。`VEER_NODE_BIN` 可指定自包含 Node（附带对应版本的 `Resources/Licenses/node-v<版本>-LICENSE`）；构建脚本拒绝依赖 Homebrew 外部 dylib 的 Node，检查当前架构和签名。当前产物是 arm64 本机构架开发包，不是 universal。

打包后的服务验证：

```sh
VEER_BUNDLED_EDITOR_ROOT="$PWD/dist/Veer AI Editor.app/Contents/Resources/editor" node scripts/test-native.mjs
```

`test-native.mjs` 启动隔离的随机端口测试服务，结束自动关闭；设置上述变量还会验证真实打包服务的生命周期与失败重试。不需要任何正在运行的 4317 服务。直接 `swift test` 没有相应环境时不会覆盖服务整合测试；bundle 测试明确按条件禁用。

## 规则集（rule-providers）

AI 理解模式可以为服务或类别添加 Mihomo 规则集，而不只是逐条域名规则：

- AI 只给出来源与名称（`metacubex-geosite`、`metacubex-geoip`、`acl4ssr`、`blackmatrix7`），地址由编辑服务按仓库规则拼出；用户粘贴的地址只接受 raw.githubusercontent.com 或 cdn.jsdelivr.net 上的 .mrs/.list/.yaml。格式、类型、路径（`./rule_provider/名称.扩展名`）与 `interval: 86400` 由服务决定，mrs 不接受混合规则。
- 每个地址在显示前用 HEAD 请求检查：404 直接拒绝并给出仓库查找指引；无法联网时标为“未验证”，卡片提醒用户在浏览器确认。
- 写入时同时新增 `rule-providers` 条目与 `RULE-SET,名称,出口` 规则；相同地址复用已有规则集，重名时自动改名，绝不修改配置中已有的规则集。新增的规则集随草稿保存，导出时合并进完整配置，不再被引用时自动移除。
- 规则集内容由客户端运行时下载，本机不做内核测试；域名测试会把 RULE-SET 标为跳过。独立规则片段模式不能添加规则集。
- 未指定出口（如“走代理”）时 AI 会先询问，可用 @ 选择完整的策略组或节点名。

## Editor Studio 重设计（2026-10-15）

按已确认的 `prototype/editor-studio` 移植到原生界面：

- **会话侧栏**：每次导入成为一个会话，保存配置、对话、草稿与撤销记录；可搜索、切换、右键删除（有未导出修改时确认）。规则稿、策略组、AI 设置移到侧栏底部。
- **加密保存**：会话包含完整配置（含节点凭证），因此以 AES-GCM 加密写入 `~/Library/Application Support/Veer/Editor/sessions.bin`（权限 0600）；256 位密钥随机生成，存于登录钥匙串（仅本机、解锁时可用）。无法解密时原文件移到旁边并保留，不会覆盖。API Key 与订阅链接不写入会话。ad-hoc 签名每次重新构建后，macOS 可能再次询问是否允许访问该钥匙串项。
- **`/` 与 `@` 补全**：输入框改为 NSTextView，知道光标位置；`/` 选择操作（`检查` 直接打开域名测试），`@` 选择服务与出口完整名称。输入法组字期间不弹出、不响应回车；回车发送，Shift 回车换行。
- **逐项审批**：每个服务一张卡片，可接受或拒绝。全部接受时直接写入候选；部分接受时把计划子集交给编辑服务（`/api/document/apply`、`/api/private/apply`）重新应用并校验后才写入。
- **检查器**（⌘I）：变更／规则／测试三个标签，可拖拽调整宽度（双击复位、聚焦后方向键调整）。规则标签显示服务解析出的规则列表并标出上次导出后新增的行；测试标签离线计算域名首条命中，GEOSITE／IP 规则明确标为跳过。
- **行为变化**：输入下一条指令不再使待审批候选失效；发送下一条指令时才失效。

## 与 editor-next 原型对齐（2026-10-15）

按 `prototype/editor-next` 补齐以下原生状态：

- **内置服务状态**：对话区顶部显示“正在启动”或“不可用”（附原因与“重新启动服务”），草稿保留在内存中。
- **出口地区确认**：导入后，无法从组名推断地区的出口在开始页列出，可就地选择；侧栏“策略组”显示未定数量。
- **AI 需要 Key**：AI 理解模式没有会话 Key 或已保存 Key 时不能发送，输入区给出设置入口。
- **AI 澄清**：服务以 `kind: "clarification"` 返回澄清问题，对话中显示为“需要澄清”的回复，而不是失败。
- **校验三态**：通过／失败／未经内核校验用不同图标与文字区分；校验失败的候选为“校验失败 · 不能确认”，确认按钮禁用。
- **增删统计**：文件条目显示 `+N −M`；页头显示“未导出”。
- **审阅双标签**：“本次修改”与“规则稿”（已确认内容、相对上次导出的增删）。
- **导出确认**：先显示导出范围与增删数，再选择保存位置；原文件不会被覆盖。

可选视觉检查：设置 `VEER_TEST_PORT`（本机测试服务）与 `VEER_SNAPSHOT_DIR` 后运行 `swift test --filter writeEditorSnapshots`，会输出关键状态的 PNG。离屏渲染不显示 Liquid Glass、侧栏选中态和消息气泡底色，只用于检查布局与文案。

## 第一版工作流

macOS 界面采用侧边栏：AI 工作台、规则稿、策略组、AI 设置。未导入时中央玻璃加号打开文件／URL 导入；导入后主区域为对话，右侧修改审阅按需展开，其他页面复用同一份草稿。导航不会丢失候选或取消请求。设置页提供持续可见的 API 地址、模型与 Key 标签。

对话显示真实处理阶段、服务→出口摘要及紧凑文件条目，点击条目审阅对应轮次的范围、Diff 和验证限制。Detail 宽度达到 1000pt 时并排，否则审阅使用单区域；关闭后保留对话历史位置和各轮范围展开状态。只有当前有效候选可确认／丢弃，历史结果只读；撤销仅对仍匹配撤销栈顶的修改有效。

macOS 26+ 使用系统 Liquid Glass 操作层和主按钮；规则/表单分区保持实底。macOS 14–25 回退为系统 material 与普通主按钮；启用 Reduce Transparency 时使用实底。没有自定义位移动画，也未改变系统外观或辅助功能设置。设计参考 Clash-Client 的侧边导航与分区层级，没有复制其源码或 VPN 能力。

撤销/检查/导出使用标题区玻璃图标按钮，窗口隐藏重复标题。提示不再常驻：普通消息 4 秒、错误 8 秒自动清除，进行中请求保持提示与取消入口；也可手动关闭。新的提示会重启计时，旧提示的计时不会清掉新消息。

从文件或订阅 URL 导入完整 Mihomo YAML，节点字段留在本机，生成只使用匿名出口上下文。地区由名称推断，不代表真实出口验证。输入指令，选择本地或 AI 模式，生成修改预览，检查完整出口和 YAML Diff。确认只更新窗口草稿，Shift-Command-Z 撤销草稿，Command-E 选择路径导出完整配置副本，Command-Return 生成预览。导出不允许覆盖导入原文件。文本编辑保留系统中文输入与原生撤销快捷键。

AI 模式使用既有按地址隔离的 macOS 钥匙串记录，原生界面只恢复状态，不回填 Key。可填写会话 Key，或主动点击保存；不会自动保存会话 Key。API 地址/模型暂不持久化，原生版暂不提供删除 Key。匿名化、协议校验与核心测试复用已有本机服务，原生客户端只接受本机端口且禁止 HTTP 重定向。服务仍是信任边界：被同用户恶意进程替换的本机服务不在此保护范围内。

草稿和对话只在内存，需及时导出；存在未导出规则、登记组名或进行中请求时，关闭窗口和退出会先确认，可选择继续编辑。单次手工规则编辑会归为一次草稿撤销，历史最多 20 项。修改组名、规则、指令或模型设置会使旧预览失效。导入成功才替换当前草稿与历史；导入失败保留原状态。导出前做结构检查，只替换已确认的 rules，不会把候选未确认规则偷偷导出，也不会将手工组名登记写成新的节点配置。

占位策略组 Mihomo 测试仅证明规则可解析，不证明实际节点可用、流量命中或网络可用。完整副本保留原配置非 rules 内容，仍应由代理客户端校验后使用；未导入完整文件时的底层导出兼容路径仅提供 rules 片段。两种输出都不是通用 OpenClash 覆写模块。

2026-10-14 落地验证：29 项 Swift Tests（VeerMac 15／VeerEditor 14）、Release 与 ad-hoc 签名通过；浅深色、最小窗口、历史位置、旧结果只读和完整副本导出完成独立原生验收。未实测真实 AI、真实订阅、VoiceOver、旧 OS 与减少透明度。详见 [验收记录](../../docs/MACOS_OPENCODE_IMPLEMENTATION_2026-10-14.md)。

## 分发限制

脚本生成本机架构、ad-hoc 签名的开发 `.app`，约 164 MB（Node 约 113 MB，Mihomo 约 46 MB）。Node、yaml、diff 和 Mihomo 许可随包保留。Mihomo 为 Veer 本地 mirror，版本 `veer-editor-local-mirror`，只以 `-t` 运行占位规则校验，不开启 VPN/TUN。

没有 Developer ID、公证、App Store/TestFlight、自动更新或 universal 二进制；公开发行前还需要审查对应源码交付与完整依赖许可。不要把当前开发构建冒充公开发行版。本轮不修改 Android 或代理内核运行逻辑。

2026-10-14 内置服务验证：Web 46 项、Swift 32 项（失败/超时各一个参数化用例）通过；独立 `/tmp` 目录的 `.app` 原生导入→本地多服务候选→占位校验→确认→完整副本导出通过，非 rules 内容逐字保留，退出与再次启动通过。真实 AI、真实订阅、实际 Key 读取、Intel/旧系统、公证本轮未验证。详见 [内置服务记录](../../docs/MACOS_BUNDLED_SERVICE_2026-10-14.md)。
