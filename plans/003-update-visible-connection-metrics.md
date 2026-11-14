# 003 — 区分连接结构变化与指标刷新

- **Status**: DONE；600唯一ID动态样例与缓存回归已运行，最终整体呈现结果见审查报告
- **Commit**: fe131e2，产品源码与 main@0533e50 一致
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: ConnectionsTable.swift 与 ConnectionsTableTests.swift

## Problem

执行：仅upload/download/rates变化时更新全部缓存，局部刷新preparedContentRect∪visibleRect内的traffic/speed及到秒时的duration；其他内容或结构变化仍全量刷新。新增预加载离屏缓存测试，避免只刷visibleRect产生旧数值。

500ms动态更新的对照中，8次full reload改为8次partial reload；divider同步步骤中位数7.64→6.95ms，最大42.74→14.98ms。刷新调用本身中位数4.67→5.75ms，不能声称局部reload每次都更快；全量刷新可能将工作推迟。以上均为CPU/布局计时，不是FPS。

macos/Sources/VeerApp/ConnectionsTable.swift:81,96–97：

```swift
let changedRows = rows != value.rows
// ...
if changedRows {
    table.reloadData()
}
```

ConnectionRow 的 Equatable 包含上传、下载与速率，因此指标变化也进入整表 reload。当前实现正确保留 ID 选择和可见行锚点；是否在面板动画时形成主要停顿，需要 001 的动态数据对照确认。

## Target

只有指标变化且 ID / 顺序 / 布局相关字段未变时，更新 coordinator 缓存并只刷新必要的可见指标单元格。结构变化继续正确更新行数、高度和锚点。离屏行重新出现时必须读取最新缓存。

## Repo conventions to follow

保留原生 NSTableView、固定列顺序、firstColumnOnlyAutoresizingStyle、横向滚动、ID 选择、右键目标与滚动锚点。使用 AppKit 的局部 reload API，不增加业务 Store 的动画状态。

## Steps

1. 在替换 rows 前区分 ID / 顺序变化、仅 upload/download/rates 变化和其他内容 / 行高变化。协议或其他布局相关字段变化不能误走指标快路。
2. 结构变化沿用完整重载及锚点恢复；仅指标变化时缓存全部最新 rows，计算当前可见行并刷新 traffic / speed，保留已有 duration 更新时间逻辑。
3. 其他内容变化先使用正确的原路径；不要为优化而错误固定 UDP 行高，或丢弃并发到来的最新连接数据。
4. 测试持续指标更新、插入 / 删除 / 重排、UDP、滚到中部、选择、右键、复制、Delete、离屏后滚回。压力测试必须使用 600 个唯一 ID。
5. 用 001 的动态 / 静态数据对照核对全表 reload 次数、动画期间更新成本与实际呈现卡顿；无收益则不扩大重构。

## Boundaries

不隐藏 / 重排列，不暂停内核或网络采集，不丢数据，不重写 Store，不改变面板宽度驱动，不恢复 snapshot 遮罩。

## Verification

完整 verify.sh 与六项既有连接表回归；新增必要行为测试。CUA 独立样例中滚动和多选不跳回，列位置保持，搜索 / 焦点 / 快捷键正确。性能轮次不截图；正确性截帧另做。不能把 reload 次数减少直接当作实际显示帧率通过。
