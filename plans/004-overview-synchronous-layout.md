# 004 — 概览在同一次布局中重排，提问栏独立保留空间

- **Status**: DONE，保留滚动底部锚点Minor
- **Scope**: OverviewView.swift、PanelResizeTests.swift、SPEC.md
- **Base**: main@0533e50，接续002与003

## 实际问题

隔离窗口的旧逐帧证据 frames-overview-reverse/0063 可见 Upload/Download 字位重叠。概览通过onGeometryChange写状态，再切换AnyLayout；宽度已变化但排列仍沿用上一帧。002只减少写入次数，不能消除这次错拍。

另一条独立路径是 if !store.agentPanel { AgentAskBar() }：面板收起一开始即插回完整输入栏，将所有卡片一次下推约64pt；这与原生分栏的连续运动不同步。

## 实现

1. OverviewCardsLayout直接在当前proposal中按原720/460页面断点量测和放置卡片。保留原半宽/四分之一宽比例、16pt间距和48pt横向边距；不观察几何、不写宽度状态。卡片身份不因横纵排列改变。
2. 提问栏从卡片流顶部移动到ScrollView.safeAreaInset(edge:.bottom)的独立区域。原生容器为它预留空间，不覆盖卡片。面板打开时仍隐藏，避免两个输入框，但只改变viewport下缘，不把整页卡片垂直推移。不再添加高度动画或逐帧环境状态，更新SPEC中的入口位置。
3. 测试同一hosting hierarchy跨断点与反向时立即取得正确高度；通过原生子视图实际frame检查两种卡片布局的边界、不相交与行数。同宽内容改变也重新量测。

## 已撤回的实验（不是当前实现）

- AskBarRevealLayout独立SwiftUI高度动画：同步step中位数13.43/max66.12ms，83steps/10toggle。
- Layout.Cache：14.81/max70.80ms，74steps；无收益，撤回。
- PanelSplitView逐帧panelRevealFraction及过渡gate：26.81/max81.38ms，67steps；同机重跑旧版11.40/max51.35ms，97steps，退化明确，全部撤回。该实验的UI21/App30/总456测试通过不能当作当前版本通过。
- 上述同步耗时不是FPS；几何正确不等于性能达标。frames-layout-*、frames-synchronized-*属于撤回实验的历史证据，不用于最终safeAreaInset方案验收。

## 验收与边界

必须区分：必要的跨断点离散重排、原先错拍产生的重影、输入栏垂直跳变，以及CPU掉帧。不能用静态图或同步divider耗时替代呈现流畅度。

旧实验标准瞬间英文Download会折行，未修改卡片文案/优先级来掩盖。最终独立复查没有新增Critical/Major，保留滚动底部开合后锚点偏移的Minor。原生Window的最小内容高度560加标题栏66，setFrame试设860×560仍被系统约束到860×626；静态场景的size也是内容尺寸，不能把实际外框860×626标成860×560。

最终454项完整检查通过；52张inset场景与后续40张新标题场景已逐张独立查看。最终动态关键帧覆盖860×626/1080×720、460/720断点、快速反向和边栏开合；Reduce Motion使用QA独立布尔覆盖并检查即时端点。轻量呈现和剩余边界见 [审查报告](../macos/docs/reviews/2026-11-13-panel-motion.md)。macOS14 VM、真实VoiceOver、全屏/多屏仍NOT VERIFIED。
