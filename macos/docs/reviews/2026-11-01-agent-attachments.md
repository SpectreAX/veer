# Agent 附件与代理页：收尾验证（2026-11-01）

范围为接手基线 `f122772` 之后的附件发送、DIRECT 专用策略组处理、错误建议及代理页布局 /
折叠修复。开发工作已本地提交，未发布；真人验收仍按下述缺口执行。

## 实现与回归

- 附件读取时按钮和 Return 共用发送限制；AppKit 的图片 / 文件粘贴进入同一附件入口。
- 引号密码、YAML 多行密钥、服务器字段脱敏；JSON 配置规范化后使用已有匿名配置视图；
  图片粘贴同样限制 25 MB。原图和原文件仅在本次运行内存中使用。
- 专用组只在接受恰好追加 DIRECT 的修改后切换。完整权限、撤销、重做均覆盖；旧延迟任务
  不能操作已经切换的配置或已经撤销的提案。普通成员修改不会误触发切换。
- 本地解析保留域名里的同名策略组片段，如 `mini4k.net`；附件丢失后给出重新添加的恢复提示。

本轮 `bash .claude/scripts/verify.sh`：格式、严格 lint、构建、410 项测试 PASS。
测试计数为 UI 12、Proxy 104、Core 291、App 3；新 App 测试覆盖读取时 Return、独立剪贴板
图片桥，以及真实隔离 Mihomo 的 DIRECT 应用 / 撤销 / 重做。测试不启动真实应用，不使用真实
配置或密钥，不调用系统代理命令；TUN 为关闭，端口来自本机临时空闲端口。

日志：仓库根目录 `.codex/local/feature-verify.log`（忽略）及
`/private/tmp/veer-finish-verify.log`。没有重生成 lint baseline 或削弱检查。

## 独立视觉与 HIG 复审

按项目 `apple-design-review` 技能由独立只读代理执行，最后复核时间为新加坡时间
2026-11-01 21:37。两处 Major（加载时 Return、full 模式只加入不切换）及恢复提示 Minor
已修复；追加 DIRECT 的误触发反例也已修复。最终范围内 Critical 0、Major 0、Minor 0。

环境：macOS 27.2、SDK 27.2；截图为隔离的发布形态构建。UI 源码与截图一致；截图后仅有
Core 解析和成员匹配逻辑的修复，最终签名构建已包含这些修复。

截图根目录：
`/private/var/folders/8b/9krhx4nn0bd2zz_0w21jj18c0000gn/T/veer-codex.7Jlwjx/macos/dist/snapshots/2026-11-01-212859/`。

以下场景在 `zh-Hans`、`en` 两个目录下的 `-light.png` 和 `-dark.png` **全部实际查看**，
共 68 张。15 个主窗口场景（60 张）通过；2 个原生 alert 场景（8 张）证据受限。

| 场景 | 尺寸 / 状态 | 结果 |
|---|---|---|
| 05-proxies、05b-proxies-smallest、05c-proxies-notice-smallest | 常规 / 最小代理页、通知 | PASS |
| 05d-proxies-latin-name-smallest、05e-proxies-panel-names、05f-proxies-names | 英文长名、面板、长策略组 | PASS |
| 09p-agent-attachments、09q-panel-attachments | 1080×720 Agent；860×640 面板 | PASS |
| 09r-agent-own-group | 专用策略组直连询问 | PASS |
| 09s-attachments-smallest | 860×560、四附件、错误提示 | PASS |
| 09t-attachments-loading、09u-attachments-unavailable | 860×560、读取中 / 附件丢失 | PASS |
| 09v-attachments-wide | 1440×900、附件 | PASS |
| 24b-panel-setup、24c-panel-narrow | 未配置 AI / 窄面板 | PASS |
| 33-tun-install、33-tun-approve | 原生 NSAlert 单独渲染 | NOT VERIFIED |

8 张 alert 的 PNG 包含透明背景，查看工具的合成底色影响文字判读；这不能证明真实弹窗存在
缺陷，也不能作为其外观通过的证据。对应源码为既有 `HelperPrompt`，本轮未修改。

| 审查类别 | 结论 |
|---|---|
| Window behavior | NOT VERIFIED：真实拖动、全屏和恢复未运行 |
| Navigation / sidebar、Toolbar | PASS：本轮源码及主窗口渲染 |
| Menu bar | NOT VERIFIED：未实际触发命令 |
| Native controls、Typography、Color / appearance | PASS；alert 证据受限 |
| Layout / resizing | PASS：最小、常规、宽窗口渲染；实时缩放未验证 |
| Keyboard / focus、Accessibility | NOT VERIFIED：桥测试和源码不代替真实按键 / VoiceOver |
| Error / empty / loading | PASS；alert 最终外观未验证 |

已读取的 Apple 官方依据：[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、
[Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)。
原规范中已记录的偏离未被重新认定为违规。

## 交付与剩余验收

开发版 `macos/dist/Veer-agent-attachments-20261101.app` 使用原有 Apple Development 身份签名；
`codesign --verify --deep --strict` 通过，最低系统 14.0、SDK 27.2。没有替换运行中的应用，
没有启动该开发版，也没有公证、发布或提高版本号。

仍需验证：真实模型识图，真实应用拖放 / ⌘V / 键盘焦点 / VoiceOver，真实窗口与动画交互、
macOS 14 VM，以及用户本人执行的系统代理 / TUN 清单。Hook 自动生命周期和发布公证的原有
验证缺口保持不变。临时日志或图片若已清理，应重新生成，不得据本文宣称新版本自动通过。
