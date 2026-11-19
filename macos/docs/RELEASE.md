# Veer for macOS：发布检查清单

每次发布按顺序走一遍。只有标着“你”的步骤需要你本人操作（涉及系统代理、TUN、系统设置或账号）。

## 1. 准备
- [ ] `Resources/Info.plist` 里提高 `CFBundleShortVersionString`（如 1.0.1）和 `CFBundleVersion`（每次加 1；Sparkle 只比较它）。
- [ ] `swift test` 全部通过（设置 `VEER_MIHOMO_BIN=$PWD/vendor/mihomo`）。
- [ ] `SnapshotRunner` 截图逐张看过：浅色、深色、中文、英文。
- [ ] `THIRD_PARTY_NOTICES.md` 和 `licenses/` 与这次打包的内容一致（Mihomo 版本、Sparkle 版本）。
- [ ] 写好更新说明（HTML 片段，存成文件，比如 `dist/notes.html`）。

## 2. 实机检查（你）
用打包好的 `dist/Veer.app`：
- [ ] 导入订阅、切换配置、切换节点、测速。
- [ ] 系统代理：打开后浏览器能用，关闭后恢复原来的代理设置。
- [ ] TUN：打开后终端 `curl` 不设代理也走 Veer；局域网和 Tailscale 地址不走 TUN；强制退出 Veer，10 秒内网络恢复。
- [ ] Agent：说一句话改分流，应用后生效，撤销后恢复。
- [ ] 开机启动开关、快捷键、备份和恢复各点一遍。
- [ ] 菜单栏：启动、停止、系统代理、TUN、模式、节点。
- [ ] 侧栏连续切换所有页面，开关 Agent 面板，不崩溃（截图每页单独渲染，测不到页面之间的切换）。
- [ ] 用鼠标拖动窗口顶部一行的空白处能移动窗口，双击能缩放（合成事件测不到系统的窗口拖动）。
- [ ] 全屏下顶部一行的按钮、标题和胶囊位置正常，能点击。
- [ ] macOS 14 虚拟机里打开一次，界面没有错位（只在界面有改动时必须做）。

## 3. 打包和签名
- [ ] `scripts/release.sh --notes dist/notes.html`（不带 `--publish`，只在本机生成）。
- [ ] 输出的 `dist/Veer-<版本>.dmg` 能打开，拖到“应用程序”后能启动。
- [ ] `dist/appcast.xml` 里的版本号、build 号、下载地址正确。
- [ ] 有 Developer ID 后：设置 `VEER_SIGN_IDENTITY="Developer ID Application: …"` 和 `VEER_NOTARY_PROFILE`，公证通过，`xcrun stapler validate` 通过。

## 4. 发布（你确认后再做）
- [ ] 提交并推送本次源码，确认工作区干净；在准确的发布提交上打 `macos-v<版本>` 并推送标签。不要覆盖已有版本或把迁移的历史标签指向新源码。
- [ ] `scripts/release.sh --notes dist/notes.html --publish`：在 `SpectreAX/veer` 建 `macos-v<版本>` release，上传 DMG 和 `appcast.xml`；`--verify-tag` 要求远端源码标签已存在。
- [ ] 打开 `https://github.com/SpectreAX/veer/releases/latest/download/appcast.xml`，内容是这次的版本，下载地址指向同仓库同标签的 DMG。
- [ ] 用上一个版本的 Veer 点“检查更新…”，能看到新版本、下载并安装，重启后“关于”里是新版本。

## 历史发布迁移（2026-11-14）

`SpectreAX/veer-releases` 的 1.0.0–1.0.6 迁入本仓库，保留原 `v<版本>` 标签、更新说明、
未公证测试版性质和 DMG 字节。只将迁入 appcast 的安装包 URL 改成 Veer 的对应附件，
EdDSA 签名、长度、版本和原始发布日期均不变。GitHub 新 Release 的发布日期由平台重新生成；
原日期和校验值保存在 [迁移清单](releases/migration-2026-11-14.json)。

这不发布新版本，也不把当前开发构建冒充为旧版。现有 1.0.0–1.0.6 安装包内仍是旧 `SUFeedURL`；
归档旧仓库只会保留旧 feed，不会自动重定向到新仓库。要迁移已安装客户端，用户须手动安装一个
使用新 feed 的后续版本，或通过经过验收、提高版本和 build 号的过渡版本完成自动迁移。
本轮不重签、覆盖历史安装包，不声称实测 Sparkle 升级。

用户随后明确选择公开 Veer，仓库已改为公开，新 feed 和附件无需 GitHub 授权即可访问。
每次发布仍须检查匿名下载和 appcast 中的 URL；仓库公开不会修改已安装客户端内置的旧更新地址。

## 已安装客户端的更新源过渡（下次新版发布）

本次只确认公开访问，未创建过渡版本。下一次获得用户发布授权时：

1. 按本清单验收新版本，版本及 build 高于 1.0.6 / 7，包内使用 Veer 的新 feed，沿用原 Sparkle 公钥。
2. 只在 Veer Releases 发布，匿名下载并核对新 appcast 的版本、签名、长度和 DMG URL。
3. 如需让仍检查旧源的客户端自动迁移，短暂解除 `veer-releases` 归档，仅将其 latest Release 的
   `appcast.xml` 更新为新 appcast，指向 Veer 中的新 DMG；不移动旧标签、不覆盖旧 DMG、不另建旧仓库 Release。
4. 验证旧 feed 返回新版本、匿名下载与签名正确，立即恢复旧仓库归档。
5. 由用户在旧 Veer 上检查、下载并安装，重启后确认版本和新 feed。没有实际运行就保持 NOT VERIFIED。

### 1.0.7 的过渡（2026-11-19，已完成）

- 用户选择让旧 feed 指向新版本。`SpectreAX/veer-releases` 临时解除归档，只把 `v1.0.6` Release 的 `appcast.xml` 换成 1.0.7 的 appcast（`gh release upload --clobber`，1,685 → 3,778 字节），随即恢复归档。没有移动标签、没有改 `Veer-1.0.6.dmg`（24,720,500 字节不变）、没有新建 Release。原 appcast 与 `releases/history/v1.0.6/appcast.xml` 逐字节相同（SHA-256 `0a860e25…2c5e76`），需要时可原样恢复。
- 匿名核对：替换后约两分钟内 GitHub 仍返回旧文件（下载链接缓存），之后 `veer-releases/releases/latest/download/appcast.xml` 与 Veer 的 1.0.7 appcast 逐字节相同，其中下载地址 `SpectreAX/veer/releases/download/macos-v1.0.7/Veer-1.0.7.dmg`，下载后 SHA-256 `919467d6…edf69`、25,189,916 字节。
- 未验证：在装有 1.0.6 的 Mac 上“检查更新…”实际找到、下载并安装 1.0.7，重启后改读新 feed。

## 注意
- Sparkle 的私钥在登录钥匙串里（账户 `com.yamax.veer`）。换电脑或重装系统前先导出备份：`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.yamax.veer -x <文件>`。丢了私钥，已安装的 Veer 就收不到更新了。
- appcast 只放最新一版，旧版本直接升级到最新。
- 没有公证的 DMG，别的 Mac 打开时会提示“无法验证开发者”，只适合自己测试。
