# macOS 分栏动画定位与修复计划

2026-11-13；基线产品代码为 main@0533e50，执行分支 codex/macos-motion-profile。本轮实现与验收完成：454项检查通过，92张相关静态图已独立查看，Critical0/Major0，保留一项滚动锚点Minor。轻量呈现对照18次热开合含100ms收尾，hitch事件45→14；仍有偶发掉帧，不能推广为固定FPS或所有场景零卡顿。报告见 [最终审查记录](../macos/docs/reviews/2026-11-13-panel-motion.md)。修复源码6b2b6ff已推送到origin/codex/macos-motion-profile，开发构建与交付记录见[HANDOFF](../.codex/HANDOFF.md)；未替换应用或发布Release。

| 顺序 | 计划 | 状态 | 依赖 |
|---|---|---|---|
| 1 | [测量真实分栏动画](001-measure-macos-panel-motion.md) | DONE，保留采样边界 | 当前源码隔离样例、解锁的交互环境 |
| 2 | [概览只保存布局类别](002-reduce-overview-width-state-updates.md) | SUPERSEDED BY 004 | 局部减少状态写入，右面板呈现卡顿未改善 |
| 3 | [连接表局部指标刷新](003-update-visible-connection-metrics.md) | DONE | 001 确认 reload 与卡顿关联 |
| 4 | [概览同帧布局与独立提问栏](004-overview-synchronous-layout.md) | DONE，保留底部锚点Minor | 逐帧确认的两处跳变 |
| 5 | [配置名原生截断](005-native-profile-name-truncation.md) | DONE | CPU采样确认重复字符串测量 |

重型650节点代理网格、macOS14、VoiceOver、全屏/多屏仍需后续验收；未扩大本轮结论。详细SwiftUI trace与轻量Animation Hitches对照分别保存，计时与正确性截帧分开；证据在忽略的 .codex/local/motion-20261113。
