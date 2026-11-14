# 001 — 建立 macOS 分栏动画的可复现性能基线

- **Status**: DONE；轻量对照确认本轮改善，单轮采样不保证固定FPS
- **Commit**: fe131e2（macos/Sources 与 origin/main@0533e50 一致）
- **Severity**: HIGH
- **Category**: Performance / interruptibility / layout correctness
- **Estimated scope**: 独立样例及测量代码；产品源码先保持不变

## Problem

用户仍报告 macOS 边栏 / Agent 面板动画异常。当前原生分栏会真实调整页面，开关途中既有连续宽度变化，也有概览断点、节点网格列数和数据刷新造成的离散变化。
已有记录包括历史主线程停顿及样例截帧，但尚无绑定当前运行二进制的完整 Instruments 因果链。旧 600 行样例重复 c0…c5，其性能比例和选择结论无效。
主线程回调间隔、setPosition 同步耗时与最终屏幕呈现帧间隔是三种指标，不能互相替代。

当前驱动位置：macos/Sources/VeerUI/PanelSplitView.swift:168–175：

```swift
split.setPosition(max(0, split.bounds.width - split.dividerThickness - width), ofDividerAt: 0)
```

同文件 153–156 行的 layoutSubtreeIfNeeded 在动画开始前执行；它以及 store.agentPanel 改变到驱动启动之间的工作都要计时。

## Target

输出一份诊断表，每条包含构建 SHA、操作、负载、窗口、刷新率、冷 / 热启动、输入到首个可见变化的延迟、主线程热点、实际呈现卡顿及证据路径。
确认异常属于：起始离散跳变、动画途中掉帧、结束补跳、几何错位 / 重影或中途反向失败。证据需能回答具体是哪次状态变化触发哪些视图更新。
保留 Motion.standardDuration=0.22、easeInOut；本阶段不调曲线，不重构容器。

## Repo conventions to follow

- 规则：根 AGENTS.md、macos/CLAUDE.md、macos/.claude/rules/*.md、macos/docs/WORKFLOW.md。
- 实际 UI 输入通过 Computer Use；不启动真实应用、不恢复真实用户代理状态、不打开系统代理或 TUN。
- 静态当前源码截图用根目录 bash .codex/scripts/snapshots.sh。动态观察需另建独立 Bundle ID、临时 Store、无内核启动的样例，打包方式沿用 build-app.sh。
- 现有真实中间提案及反向回归在 macos/Tests/VeerUITests/PanelSplitTests.swift；保留其断言。
- 使用 Xcode Instruments 的 SwiftUI Cause & Effect、Time Profiler 和可用的呈现卡顿轨道。使用 OSSignposter 对齐关键阶段。

## Steps

1. 核对待测 .app 的绝对路径、构建 SHA、是否含当前 PanelSplitView；仅版本号 1.0.6/7 不足以证明源码一致。记录 OS、SDK、显示刷新率和 Reduce Motion。样例从当前源码新建，不使用 /private/tmp/veer-panel-native 的旧二进制。
2. 在隔离样例添加 signpost：ToggleIntent、SwiftUI提交 / 可观察的布局准备、NativeDriverStart、每次 DividerStep、TableReload 和 AnimationEnd。记录实际左右栏 frame 及页面收到的宽度。不要将设置 divider 的返回视作屏幕已呈现。
3. 第一轮固定 1080×720、zh-Hans、深色，按页面分别测左边栏和右面板；分别做一次冷切换及 10 组热开关，单独测快速反向。不能同时改变多个变量。
4. 分别以纯色正文 / 真实正文、纯色面板 / 真实面板形成四组对照；再比较冻结示例数据与持续示例更新。冻结仅是诊断对照，不是默认产品修复。
5. 真实正文分普通负载、600 条唯一 ID 连接、10×65 个唯一节点。启动前断言 ID 全部唯一。不得读取真实订阅或 Key。
6. 不截图、不在动画中查询 AX 的性能轮次用于 Instruments 计时；另做慢放 / 合成帧正确性轮次检查布局和重影。两类证据分开。
7. 从最长停顿向前追 cause graph：是几何写回状态、网格断点 / 首次创建、表格 reload、Agent 内容构建、工具栏偏好，还是呈现阶段。分别标记 CPU 布局 / 视图更新 / 合成；只优化占主要成本的路径。
8. 按证据选择 002 / 003，或另写代理页优化计划。若纯色正文和面板都能复现明显停顿，再优先审查 PanelSplitView / SidebarAnimator；否则先缩小页面更新范围。

## Boundaries

- 保留页面与面板真实分栏、正文单层、可交互；不叠加旧截图，不缩放文字，不用直接 child frame 改值掩盖 SwiftUI 未收到提案的问题。
- 保留已选定的连接表固定列 / 横向滚动方案；代理页外层非 lazy VStack 是折叠行为的既有权衡，不直接替换。
- 不改 Android / iOS，不发布或替换正式 app；不放宽 lint、测试和 Reduce Motion 行为。

## Verification

- 每种归因都有至少一组仅改变该因素的前后 trace，所有对照使用同一构建配置与合成数据。
- 60 Hz 的整帧预算约 16.7 ms，120 Hz 约 8.3 ms；记录实际呈现及 hitch 指标。帧率请求设为 60 不等于实际达到 60。
- 针对修复前后比较首帧延迟、呈现卡顿、布局耗时、视图更新次数；一次独立因果改动后就复测。
- 正确性验收：开 / 关 / 快速反向时真实宽度连续、左右栏不相交、无补跳和重影，滚动 / 选择 / 搜索 / 焦点不丢。
- 扩展至 860×560、1440×900、中英文及深浅色、Reduce Motion。macOS 14、VoiceOver、全屏 / 多显示器未运行就标 NOT VERIFIED。
- 产品实现后执行 cd macos && bash .claude/scripts/verify.sh，再做项目视觉审查和独立 Apple 设计审查。锁屏下动画测试失败需解锁后重跑，不能直接归因为产品 bug 或跳过。

## References

- https://developer.apple.com/videos/play/wwdc2025/306/
- https://developer.apple.com/documentation/os/ossignposter
