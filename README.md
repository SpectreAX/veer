# Veer

用 AI 决定流量走向的代理工具：一句话改分流（“Netflix 走日本”），审阅后立即在运行中的 Mihomo 内核生效。

| 目录 | 平台 | 状态 |
|---|---|---|
| [`macos/`](macos/) | macOS 14+（SwiftUI，26+ Liquid Glass） | 主要功能已实现；Agent 附件和代理页修复已落地，待剩余实机验收 |
| [`ios/`](ios/) | iOS 26+ | 仅在模拟器中评估的原型，不对外分发 |
| [`android/deprecated/`](android/deprecated/) | Android 10+ | 旧版历史归档，暂停开发 |

macOS 版独立构建，不依赖其他仓库：`cd macos && scripts/build-mihomo.sh && scripts/build-app.sh`。计划见 [`macos/docs/PLAN.md`](macos/docs/PLAN.md)。

## macOS 下载与发布

安装包和版本说明统一放在本仓库的 [Releases](https://github.com/SpectreAX/veer/releases)。
原 `SpectreAX/veer-releases` 的 1.0.0–1.0.6 按原版本迁入，安装包保持原样；这是历史发布迁移，
不包含之后的动画修复。原仓库转为只读归档，保留旧下载链接。
Veer 保持私有，迁入后的下载需要仓库访问权限，普通 Sparkle 请求无法访问新 feed；
公开下载与自动更新需另行确定分发方式。旧版本内置的旧更新地址不会自动切换。

迁入的历史版本仍使用原 `v<版本>` 标签；后续 macOS 发布使用源码标签 `macos-v<版本>`。
发布流程见 [`macos/docs/RELEASE.md`](macos/docs/RELEASE.md)，校验和与迁移边界见
[`macos/docs/releases/README.md`](macos/docs/releases/README.md)。

## Android 历史归档

旧仓库 [SpectreAX/veer-android](https://github.com/SpectreAX/veer-android) 的默认分支 `main` 已迁入
[`android/deprecated/`](android/deprecated/)，保留原始文件、Git 提交历史及 Git LFS 内核库。
归档快照为 [`7f1af61`](https://github.com/SpectreAX/veer-android/commit/7f1af61ded6785d366629227047832a6327268e2)。
原仓库转为只读归档，其他历史分支仍可在那里查阅。

该目录仅供历史参考，不属于当前 macOS 或 iOS 构建。其 README 中的旧 macOS 编辑器和 Web 原型说明也属于历史记录；
当前 macOS 客户端以 [`macos/`](macos/) 为准，独立的 Veer AI Editor 仍在原有仓库中维护。

Claude / Codex 共用的规则、环境、技能和检查流程见 [`macos/docs/WORKFLOW.md`](macos/docs/WORKFLOW.md)，当前交接见 [`.codex/HANDOFF.md`](.codex/HANDOFF.md)。

Veer 自有代码版权所有 © 2026 SpectreAX。保留所有权利，见 [`macos/LICENSE`](macos/LICENSE)。
历史归档中的第三方代码保留各自的版权和许可声明。
