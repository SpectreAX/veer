# Veer

用 AI 决定流量走向的代理工具：一句话改分流（“Netflix 走日本”），审阅后立即在运行中的 Mihomo 内核生效。

| 目录 | 平台 | 状态 |
|---|---|---|
| [`macos/`](macos/) | macOS 14+（SwiftUI，26+ Liquid Glass） | 主要功能已实现；Agent 附件和代理页修复已落地，待剩余实机验收 |
| `android/` | Android | 独立仓库 [SpectreAX/veer-android](https://github.com/SpectreAX/veer-android)，在本地检出到这个目录（已忽略） |

macOS 版独立构建，不依赖其他仓库：`cd macos && scripts/build-mihomo.sh && scripts/build-app.sh`。计划见 [`macos/docs/PLAN.md`](macos/docs/PLAN.md)。

Claude / Codex 共用的规则、环境、技能和检查流程见 [`macos/docs/WORKFLOW.md`](macos/docs/WORKFLOW.md)，当前交接见 [`.codex/HANDOFF.md`](.codex/HANDOFF.md)。

版权所有 © 2026 SpectreAX。保留所有权利，见 [`macos/LICENSE`](macos/LICENSE)。
