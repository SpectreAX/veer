# Veer 自定义 DNS 设置设计

日期：2026-07-30  
状态：已完成并通过模拟器/真机验证

## 目标

为每个配置文件提供独立的 DNS 设置，使用户无需编辑 YAML 即可选择：

- 跟随订阅或导入文件中的 DNS；
- 自定义普通 DNS、DoH 或 DoT；
- 选择 `fake-ip` / `redir-host`；
- 控制 IPv6 DNS 响应；
- 设置 bootstrap、主要和 fallback 服务器。

运行中的活动配置保存后必须经过既有的安全停止、重新启动和失败回滚链路，不能
热改一个仍在持有 TUN 的 Mihomo 实例。

## 存储模型

每个 profile 使用三层数据：

```text
{id}_raw.yaml          原始订阅或导入内容
{id}_base_config.yaml  导入管线生成、尚未应用用户 DNS 覆写的安全配置
{id}_config.yaml       实际交给 Veercore 的有效配置
```

DNS 覆写策略保存在 `ProfileIndex.dnsOverrides`，以 profile ID 为键。这样：

- 切换 profile 不会串用 DNS；
- 订阅刷新会替换 base，再重新应用同一份覆写；
- 选择“跟随配置”可恢复最新订阅的 DNS，而不是第一次修改前的旧副本；
- 删除 profile 时同时删除 base 和覆写。

旧版本只有 `{id}_config.yaml`。首次读取时把它作为 base，保证无损迁移。

## 支持与校验

主要和 fallback 服务器支持：

- 纯 IPv4 / IPv6 地址；
- `https://host/path`（DoH）；
- `tls://host[:port]`（DoT）；
- `tcp://`、`udp://`、`quic://`。

Bootstrap 只接受纯 IP，避免解析 DNS 服务器域名时形成依赖环。输入按行分隔、
去空白、去重；每组最多 8 项，每项最多 512 字符。拒绝凭据、非法端口、DoH
空路径、fragment、未知协议和非数字的裸主机名。

## 应用与回滚

- 非活动 profile：原子保存覆写和有效配置，不影响当前 VPN。
- 活动 profile 且 VPN 停止：保存后更新 `ConfigManager`，下次启动生效。
- 活动 profile 且 VPN 运行：
  1. 快照当前有效配置、覆写和哈希；
  2. 通过 `prepareProfileSwitchIntent` 安全排空旧核心；
  3. 保存候选 DNS 配置并启动；
  4. 等待真实 `Running`；
  5. 启动失败则恢复持久化快照并重新启动旧配置。

整个流程继续服从 `engineMutex`、单一 Go runtime、Stop 超时不可恢复等运行时约束。

## UI

- 首页快捷操作增加“DNS 设置”；
- 页面明确显示当前活动 profile；
- “跟随配置 / 自定义 DNS”互斥；
- 自定义模式显示 enhanced mode、IPv6、bootstrap、主要和 fallback 输入；
- 输入错误在保存前逐项汇总；
- 运行中显示“保存并安全重连”，停止时显示“保存”；
- 保存期间锁定所有编辑与重复提交。

## 验收

1. 校验器覆盖 IPv4、IPv6、DoH、DoT、端口、凭据和非法协议。
2. YAML 覆写只修改 DNS，代理、策略组和规则保持不变。
3. 订阅刷新后仍保留当前 profile 的 DNS 覆写。
4. 切换回“跟随配置”恢复最新 base DNS。
5. 不同 profile 的覆写互不影响，删除 profile 会清理覆写。
6. 运行中保存完成安全重连；注入启动失败时恢复原配置。
7. Compose 页面可切换模式、编辑字段、看到校验错误并触发保存。
8. 单元测试、Lint、Debug/Release/AndroidTest 构建以及真实 DNS/公网探针通过。

## 实施结果

- 首页和每张 profile 卡片均可进入 DNS 页面；从 profile 卡片进入时也支持修改
  非活动配置，不会中断当前 VPN。
- `ProfileIndex.dnsOverrides` 按 profile ID 保存版本化策略；旧索引缺少该字段时
  自动迁移为空映射。
- 导入和订阅刷新始终写入新的 base 配置，再应用该 profile 的覆写生成有效配置。
- 选择“跟随配置”会移除覆写并恢复最新 base 的精确字节。
- 普通 DNS、DoH、DoT、TCP、UDP、QUIC、IPv4/IPv6、端口、凭据和路径均在保存
  前校验；Bootstrap 限制为纯 IP。
- 活动 VPN 保存使用既有 `ProfileRuntimeSwitchCoordinator`，复用安全停止、
  真实 Running 确认和失败回滚，不新增第二套生命周期协议。
- 启动失败回滚同时恢复有效 YAML、DNS 策略、metadata hash 和 active hash，
  避免只恢复当前内存、下次启动又读到失败候选。

## 验证记录

- 新增校验器、YAML 覆写、旧索引迁移和 profile 隔离单元测试；完整 Debug
  单元测试通过。
- Compose 测试验证跟随/自定义切换、输入区域、解析模式和运行中安全重连操作；
  Android 16 arm64 完整仪器套件 **19/19** 通过。
- 在 Android 16 模拟器的真实活动订阅上保存推荐 DoH：
  - 页面报告 DNS 已应用且 VPN 已恢复；
  - Controller HTTP 200；
  - `/dns/query` HTTP 200 并返回 A 记录；
  - gstatic 经 Mihomo 返回 HTTP 204。
- 切回“跟随配置”后，有效配置与 base 文件逐字节一致，DNS 查询 200、代理公网
  204。
- 注入一次原生启动失败后，页面明确报告已恢复原配置并重新连接；持久化有效配置
  与 base 再次逐字节一致，最终 Running、Controller 200、DNS 200、代理公网 204。
- HyperOS / Android 13 arm64 真机重新执行生命周期矩阵 **14/14**；安装恢复后
  最终 Running、Controller 200、DNS 查询 200、代理公网 204。
- 干净源码门禁通过：`testDebugUnitTest`、`lintDebug`、Debug、AndroidTest 和
  R8 Release。Universal Debug 的 D8 合并需要 6 GiB 临时 Gradle 堆。
