# Veer

用 AI 决定流量走向的代理工具：一句话改分流（“Netflix 走日本”），审阅后立即在运行中的 Mihomo 内核生效。

| 目录 | 平台 | 状态 |
|---|---|---|
| [`macos/`](macos/) | macOS 26（SwiftUI） | 第 1 阶段：导入配置、运行内核、切换节点、系统代理、菜单栏 |
| `android/` | Android | 独立仓库 [SpectreAX/veer-android](https://github.com/SpectreAX/veer-android)，在本地检出到这个目录（已忽略） |

macOS 版独立构建，不依赖其他仓库：`cd macos && scripts/build-mihomo.sh && scripts/build-app.sh`。计划见 [`macos/docs/PLAN_2026-10-29.md`](macos/docs/PLAN_2026-10-29.md)。

版权所有 © 2026 SpectreAX。保留所有权利，见 [`macos/LICENSE`](macos/LICENSE)。
