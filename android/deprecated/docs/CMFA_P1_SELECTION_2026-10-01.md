# P1-C：策略组选择按 Profile 隔离

日期：2026-10-01

## 问题与改法

Mihomo 默认把 Selector 选择写入全局缓存。同名策略组跨 Profile 复用时会把 A 的选择应用到 B，且不会校验 B 是否仍包含该节点。

Veer 现在在最终运行配置中设置 `profile.store-selected: false`，保留其他 `profile` 字段；所有手动、自动恢复和 AI 切换仍经 `MihomoRepository.selectProxy`，成功后统一保存到 app 私有、按 Profile ID 隔离的文件。核心每次启动且 Controller 就绪后，仅恢复当前 Selector 仍包含的成员，并删除失效记录；无 Profile 的基础配置使用独立默认作用域。删除 Profile 时删除其选择记录。进程间写入通过文件锁和原子替换串行化。

## 验证

- `:app:testDebugUnitTest :app:assembleDebug -Pveer.abiSplits=true`：通过。单元测试覆盖不同 Profile 同名组的独立存储和无效成员过滤。
- Android 36.1 arm64 模拟器：A（`veer-validation`）的 `PROXY` 选择 `DIRECT-TEST`，完整强制停止、重启 VPN 后仍恢复该选择；运行状态为 `Running`、Controller available、Internet reachable。
- 导入成员不同的 B（`profile-b`，`PROXY` 含 `DIRECT`/`B1`）。激活 B 后初始为 `DIRECT`，没有继承 A 的 `DIRECT-TEST`；选择 `B1`，切回 A 恢复 `DIRECT-TEST`，再次切 B 恢复 `B1`。
- 已确认运行配置为 `store-selected: false`，两个 Profile 分别生成独立的选择文件。
- 用最终 arm64 APK 覆盖安装后，B 再次启动达到 `Running`、Controller available、Internet reachable，`PROXY` 仍恢复为 `B1`。
- 2026-10-01 设备端回归（Android 36.1 arm64 模拟器）：新增 `ProfileSelectionRefreshInstrumentedTest`，通过正式 `ProfileManager.import(..., existingId=同一 ID)` 把测试 Profile 的 `PROXY` 从 `DIRECT/TO_DELETE` 更新成 `DIRECT/REPLACEMENT`。第一次启动选中 `TO_DELETE` 并确认已保存；停止、更新、重新启动后，断言组成员不再含旧节点、当前选择为 `DIRECT`，且持久化记录不再含 `PROXY`。两次启动都达到 `Running` 且 Controller readiness 通过。`am instrument -w -e class com.yamax.veer.testing.ProfileSelectionRefreshInstrumentedTest com.yamax.veer.test/androidx.test.runner.AndroidJUnitRunner` 返回 `OK (1 test)`；测试结束恢复原活动 Profile 并删除测试 Profile。

这次是同一 Profile 的设备端重新导入，覆盖配置解析、持久化和核心重启路径；不是远端 HTTPS 订阅下载测试。当前无真机连接，不能把模拟器结果标成真机结果。AI/自动恢复调用共享的 `selectProxy`，本轮未分别触发这两类运行时事件。
