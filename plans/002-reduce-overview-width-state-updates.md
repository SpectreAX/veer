# 002 — 把概览的宽度状态收窄为布局类别

- **Status**: IMPLEMENTED AND MEASURED，现由 004 的同步 Layout 取代
- **Commit**: fe131e2，产品源码与 main@0533e50 一致
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: OverviewView.swift 与对应 App 测试

## Problem

执行结果：布局类别使面板10次切换的状态写入102→10、边栏6次52→0。边栏同步 divider-step 中位数16.71→12.10ms，但右面板9.69→11.14ms；同条件 trace 的15个热循环呈现卡顿29→34次。不能认定右面板性能改善。后续逐帧发现断点状态仍晚一帧、输入栏开关高度突变，因此由004直接在Layout提案内判定排列，不保留宽度状态。

macos/Sources/VeerApp/OverviewView.swift:12 保存完整 CGFloat 宽度，51–56 每次宽度变化写回 @State：

```swift
.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
    var layout = Transaction(animation: nil)
    layout.disablesAnimations = true
    withTransaction(layout) { width = new }
}
```

这个状态只在 720 与 460 两个断点被读取。源码确认存在逐宽度状态变化；它是否构成本次主要卡顿仍需 001 测量，不能提前认定已找到根因。

## Target

将观察值改为 Equatable 布局类别，只保存两个布尔量：实际宽度 <720、实际宽度 <460。连续宽度仍由原生分栏提供，视图继续实际排版；只在跨断点时写布局状态。

## Repo conventions to follow

沿用 OverviewView.stackBelow=720、stackPairsBelow=460、当前无动画 Transaction 和原有 AnyLayout。保持实际宽度判定；不得提前按面板最终目标宽度摆宽布局。

## Steps

1. 添加局部、可测试的布局值类型，将 CGFloat 映射为 stacked / stackedPairs；以 width=0 的结果初始化，保持原始首次布局语义。
2. 将 onGeometryChange 的 Equatable 观察值改为此类型，而不是原始宽度；保留现有 disablesAnimations 事务。
3. row / pair 只读取布局类别，删除不再需要的原始 width 状态；不改变卡片顺序、内容或边距。
4. 添加断点测试：459、460、461、719、720、721；同区间内多个宽度返回同一类别。用 001 对照布局状态写入次数和视图更新成本。

## Boundaries

不调曲线 / 时长，不更换分栏，不改其他页，不重引入目标宽度导致的概览竖排问题。此改动不能消除必要的几何排版，禁止声称只是减少状态变化就保证 60 fps。

## Verification

完整 verify.sh；相同数据与窗口下复测。开关和反向跨 720 / 460 时文字保持可读，几何连续；同一断点区间内布局状态不逐帧变化。独立查看中英文、深浅色、窄 / 标准 / 宽窗和 Reduce Motion。
