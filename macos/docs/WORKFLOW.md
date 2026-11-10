# Veer：Claude / Codex 共用开发环境

两者使用同一份源码、规则、构建工具和验收标准。Codex 的入口在仓库根目录
`AGENTS.md`、`.codex/` 和 `.agents/skills/`；Claude 继续使用现有 `.claude/`。
不要将 Claude 的会话 JSON、API Key、订阅链接或签名私钥放入 Git。

## 规则与上下文

1. `macos/CLAUDE.md` 是开发规则入口，`macos/.claude/rules/*.md` 是七条完整规则。
2. 产品行为以 `docs/SPEC.md`、`docs/REQUIREMENTS.md` 为准；设计以 `DESIGN_SPEC.md`、
   `Design/TOKENS.md`、`Design/COMPONENTS.md` 和 Apple HIG 为准。
3. 模块的 `CLAUDE.md` 记录该模块的额外约束。Codex 配置也将这个文件名识别为规则回退入口。
4. `.codex/HANDOFF.md` 记录中断点、未完成工作及验证证据。历史通过不等于本次通过。
5. Claude 的原始项目记忆在本机 `~/.claude/projects/-Users-spectreax-Developer-Veer/memory/`；
   接入时的副本在忽略的 `.codex/local/claude-memory/`，供追溯，不作为当前进度来源。

从仓库根目录或 `macos/` 开始工作均可。Codex 的 SessionStart Hook 会注入共享规则和
交接记录，并在 resume、fork、compact 等生命周期重新加载；入口规则还要求主动读取，
所以未启用 Hook 时也必须遵守。不能仅凭配置文件声称 Hook 已运行。

## 保留的用户决定

- 当前 macOS 客户端与旧的 `~/Developer/veer-editor` 独立；Android 在独立仓库。
  VeerCore 的共同修复按需手动移植，不引入跨仓库构建依赖。
- 目标是帮助不熟悉 YAML 的订阅用户；原生主窗口和 Agent 是核心界面。
  macOS 免费、没有试用检查；商店版和移动端内核选型是后续独立工作。
- 一个构建支持 macOS 14 起的系统；新系统的 Glass API 留在 VeerUI，并保留回退。
- 用“我的分流”操作层重放订阅上的修改；失败必须报告。配置修改默认审阅后应用，
  运行状态操作可撤销。具体执行模式和附件限制以当前 SPEC 和代码为准。
- 支持简体中文、英文、键盘、VoiceOver、减弱动态效果。沿用 `.strings`，不顺手迁移。
- AI 上下文先匿名化；不读取或展示真实 Key、订阅链接或私钥来接入开发环境。
  密钥存储遵循当前 Keychain 实现，旧记忆的“开发版只存文件”已过时。
- 不开启系统代理、TUN 或会触发它们的回退路径；对应实机测试由用户运行。
- 无遥测；备份不含 API Key，订阅链接可选。Mihomo 保持独立进程，许可与第三方声明保留。
- 自用测试沿用免费 Apple Development 签名；公证需要 Developer ID 和付费账号。
  不为测试新买账号、生成或导出签名密钥。每次正式发布都要单独得到用户指示。

## 环境与常用命令

2026-11-01 本机盘点：Apple Silicon、macOS 27.2、Xcode 已安装，SDK 27.2，Swift 6.4.2，
SwiftFormat 0.64.4、SwiftLint 0.65.1、Go 1.27.3、GitHub CLI 2.103.3。
终端 Codex CLI 为 0.162.1；当前桌面内置 CLI 为 0.166.0-alpha.5.1，路径是
`/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。
这些是盘点值；后续以命令的实际输出为准。旧记忆和文档中“没有 Xcode”的描述已失效。

在 `macos/` 运行：

```bash
bash .claude/scripts/verify.sh              # 格式、lint、构建、全部测试
bash .claude/scripts/verify.sh --lint-only  # 只检查格式和 lint
scripts/build-mihomo.sh                    # 只有内核缺失或需要重建时才运行
scripts/build-app.sh                       # 打包发布形态；先确认目标应用没有在运行
```

`verify.env` 和 `build-app.sh` 已设置 Xcode 的 SDKROOT，不能改用缺少 SwiftUI macro plugin
的旧 Command Line Tools SDK。测试在 `vendor/mihomo` 存在时自动设置 `VEER_MIHOMO_BIN`。
SwiftPM 依赖锁定在 `Package.resolved`；Sparkle 工具在 `.build/artifacts/sparkle/Sparkle/bin/`。
钥匙串只检查签名身份的存在，不导出 Sparkle 私钥，也不重新生成已投入使用的 Key。

从仓库根目录安全地构建并截图：

```bash
bash .codex/scripts/snapshots.sh
```

该命令在临时目录复制当前 macOS 源码，构建并临时签名自己的应用，只通过现有截图模式
启动，输出构建日志和截图目录。不会替换运行中的 `macos/dist/Veer.app`。可设置原有的
`VEER_SNAPSHOT_LANGUAGES=en`、`VEER_SNAPSHOT_APPEARANCE=light` 缩小矩阵。
验证整套环境时用默认中英文、深浅色矩阵。临时副本保留至检查完成，之后只清理自己创建的目录。

SnapshotRunner 的独立窗口不能证明真实 Window scene、拖动、全屏或页面切换的行为。
如果要复现真实窗口，另建隔离副本，使用示例 Store、独立 Bundle ID 和构建成功后的长字符串
guard；先确认不会走真实 `store.launch()`。不要用未经检查的旧二进制启动。

## Hooks

| 时机 | Claude | Codex |
|---|---|---|
| 启动 / 恢复 / 压缩 | 项目规则及记忆 | SessionStart 注入共享规则与交接记录 |
| 编辑 Swift 文件后 | Write / Edit → post-edit.sh | apply_patch / Edit / Write → 事件适配器 → 同一 post-edit.sh |
| 结束前 | stop-check.sh | Stop → 同一 stop-check.sh |

Codex 的补丁一次可改多个文件，适配器把补丁路径转换为原 Hook 的 `file_path`。
删除、项目外文件和非 Swift 文件不会被格式化。通过 shell 修改的 Swift 仍由 Stop 和全量
verify 检查。Stop 失败时阻止一次，重试仍失败则明确报告，沿用原脚本的防循环设计。
Hooks 不运行构建、测试或视觉审查，不能替代完整验收。

Codex 项目 Hook 需要可信项目，并按当前定义单独信任。配置在 `.codex/hooks.json`，
使用 CLI `/hooks` 审阅和启用；定义变化后需重新审阅。不要设置跳过信任检查的参数。
当前会话若尚未加载配置，显式执行检查，并在新的会话启动时核对自动触发记录。

## 技能与工具对应

| 原工作流 | Codex 入口 / 替代方式 |
|---|---|
| `/macos-feature` | `$macos-feature`，共享原有理解、设计、实现、验证流程 |
| `/macos-visual-audit` | `$macos-visual-audit`，真实截图使用 `view_image` 逐张查看 |
| `/apple-design-review` 的 fork | `$apple-design-review`，独立只读子代理审查，主代理修复 |
| `/macos-release-check` | `$macos-release-check`，保留显式调用和只读检查边界 |
| Bash、Read、Edit | exec_command、文件读取、apply_patch |
| update_plan / wrap_up 卡片 | 进度消息、交接记录及最终报告；不冒充 Claude 的 UI 卡片 |
| 图片附件 / 临时证据 | 原路径可读时直接使用；丢失时标为 NOT VERIFIED |
| 真实窗口和交互 | 现有 computer-use 工具；先检查能力与授权，不直接套用 AppleScript 点击 |
| Git、PR、发布 | Git 和 gh；沿用当前分支和原 release.sh，不自动执行历史对话里的命令 |

`~/.claude/skills/` 中原有 macOS 参考资料仍保留：`macos-patterns`、`macos-design`
及 references、`macos-settings-ui`、`macos-notch-ui`、`macos-auto-update`、`macos-build`、
`macos-release`。通过 `$veer-macos-reference` 按需读取；模板不能覆盖本项目的 SwiftPM、
VeerUI、现有 Settings / Updater 或发布流程。不批量复制通用技能，以免重复触发和引入旧假设。
已有 Codex 的 Ponytail、grill-me、impeccable 技能承担对应通用流程；旧项目的
`.claude/skills/impeccable` 及 `.claude/agents/` 留作原版本参考。原根目录 launch.json
指向历史 /tmp 内核实验，不是当前 app 的启动配置，不注册为自动启动项。

## 验收与交接

遵循 `CLAUDE.md` 的完成标准：全量 verify；UI 改动还需截图审查及独立 HIG 审查；
Critical / Major 清零；macOS 14 VM、VoiceOver、键盘和网络相关实机项根据实际证据报告。
没有运行就写 NOT VERIFIED。不要放宽 lint、重生成 baseline 或弱化测试来通过。

提交前检查 diff、敏感信息、版本及无关文件，按完整功能组织提交。用户只是要求接入环境时，
不顺带提交原来未完成的功能，也不发布。交接记录写清：本轮范围、改动、检查的结果、
证据路径、未完成项和下一步；不要依赖某个聊天的完整历史才能继续。

配置依据：[AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、
[本地技能](https://learn.chatgpt.com/docs/build-skills)、
[Hooks 与信任](https://learn.chatgpt.com/docs/hooks)。
