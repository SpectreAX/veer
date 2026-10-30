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
- [ ] `scripts/release.sh --notes dist/notes.html --publish`：在 `SpectreAX/veer-releases` 建 `v<版本>` release，上传 DMG 和 `appcast.xml`。
- [ ] 打开 `https://github.com/SpectreAX/veer-releases/releases/latest/download/appcast.xml`，内容是这次的版本。
- [ ] 用上一个版本的 Veer 点“检查更新…”，能看到新版本、下载并安装，重启后“关于”里是新版本。
- [ ] 提交并推送这次的代码改动，打 tag `macos-v<版本>`。

## 注意
- Sparkle 的私钥在登录钥匙串里（账户 `com.yamax.veer`）。换电脑或重装系统前先导出备份：`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.yamax.veer -x <文件>`。丢了私钥，已安装的 Veer 就收不到更新了。
- appcast 只放最新一版，旧版本直接升级到最新。
- 没有公证的 DMG，别的 Mac 打开时会提示“无法验证开发者”，只适合自己测试。
