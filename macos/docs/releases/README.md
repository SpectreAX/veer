# macOS 发布归并（2026-11-14）

发布入口为 [SpectreAX/veer Releases](https://github.com/SpectreAX/veer/releases)。
本轮只迁移已经发布的 1.0.0–1.0.6，不重建、不重签、不覆盖历史 DMG，也不发布新的开发构建。

- `legacy/README.md`：原发布仓库 `main@76f9eb2946e063fc1fa19fdff8c606f62f7d1405` 的完整文件树，
  以非 squash subtree 保留原始提交。原仓库只有这一份 README 和一个 Git 提交。
- `history/v*/`：原始 appcast 和原始更新说明；appcast 内旧下载地址是历史证据。
- `migration-2026-11-14.json`：原发布时间、附件大小、SHA-256 和迁入 appcast 的 SHA-256。
  GitHub 重新生成 Release ID、附件 ID 和发布时间，无法保留原网页发布时间。
- 原 `v1.0.0`–`v1.0.6` 标签保持指向原发布仓库的 README 提交，不能当成应用源码版本。
  Veer 已有的 `macos-v1.0.3`–`macos-v1.0.6` 才是对应的源码标签；不移动这些标签。
  后续发布脚本只使用已经推送的 `macos-v<版本>` 标签。

DMG 放在 GitHub Releases，不将约 169 MB 的历史二进制加入 Git。迁入 appcast 仅替换
`enclosure.url` 的仓库路径；版本、日期、长度和 EdDSA 签名保持原值，原始 DMG 的 SHA-256 必须完全一致。
旧仓库保留历史 Release、附件和旧 feed，归档后不再发布。

## 更新链路的边界

源代码的 `Info.plist` 已改为新 feed，但复制安装包不会改包内的 `SUFeedURL`。
1.0.0–1.0.6 仍检查旧仓库，归档不会把它们自动转到新 feed。下一次发布新版本时，需要明确安排
手动安装新包或先发过渡版本；不能复用 1.0.6/build 7 来伪造升级。旧客户端的 Sparkle 端到端迁移
为 **NOT VERIFIED**，本轮不启动真实应用、不替换用户安装。

用户随后明确选择公开 Veer，已将包含完整源码及 Git 历史（含 Android 归档）的仓库改为公开。
新 feed 和安装包无需 GitHub 登录或令牌即可访问，旧仓库继续保留只读归档和原公开下载。

## 本次检查

7 个历史 Release 已发布，最新为 1.0.6；14 个新附件已实际下载，大小和 SHA-256 均符合预期。
7 个 DMG 使用 Info.plist 中的公钥验证 Ed25519 签名全部通过。原始提交可达，subtree 文件树一致，
标签未移动。旧仓库归档状态已确认，归档后的旧公开 feed 和最新 DMG 均 HTTP 200、摘要不变；
最初私有状态时新 feed 匿名请求为 HTTP 404；在收到公开授权并更改可见性后，重新检查匿名下载。
公开后全部 14 个附件及新 latest feed 均匿名 HTTP 200，大小和 SHA-256 正确，7 个 DMG 的
Ed25519 签名通过。最新 1.0.6 DMG 完整性及深度严格包签名通过；只读挂载检查确认 build 7、
内置旧 feed，随后已卸载，没有启动应用。旧 feed 内容不变，旧仓库说明已更正为公开并确认归档。

本轮完整 `verify.sh`：448 项通过（20 UI + 111 Proxy + 294 Core + 23 App），格式、严格 lint 和构建通过。
脚本语法、plist、diff 检查和隔离发布脚本检查通过；隔离检查替代构建、签名和上传，验证无 `--publish`
不发布，以及新 URL、源码标签要求、显式 latest 和发布参数。没有新的产品 UI 改动，未重复视觉审查。
本地证据在忽略的 `.codex/local/release-migration-20261114/`，没有将安装包或本机凭据加入 Git。
公开确认这一步再次运行完整 verify，仍为 448 项通过；匿名访问、签名和挂载记录位于
`.codex/local/release-public-20261114/`。既有客户端过渡步骤见 [发布清单](../RELEASE.md)，端到端升级仍 NOT VERIFIED。

依据：[Sparkle feed 配置](https://sparkle-project.org/documentation/publishing/#setting-the-feed-programmatically)、
[GitHub 仓库归档规则](https://docs.github.com/en/repositories/archiving-a-github-repository/archiving-repositories)。
