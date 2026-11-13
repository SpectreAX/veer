# Veer OEM 后台运行检测与引导

日期：2026-07-30  
状态：核心实现与锁屏真机验证已通过；解锁后的可见 UI 操作待人工验收

## 目标

让用户在 MIUI/HyperOS 等后台限制较强的系统上知道 Veer 为什么可能在锁屏后断开，
并能通过明确的用户操作进入正确的系统设置页。Veer 不申请设备管理权限，不执行
ADB 命令，也不静默修改省电、自启动或后台运行策略。

## 检测边界

Android 公开 API 可以可靠读取：

- `PowerManager.isIgnoringBatteryOptimizations(packageName)`；
- `ActivityManager.isBackgroundRestricted`；
- `UsageStatsManager.appStandbyBucket`；
- `PowerManager.isPowerSaveMode`；
- 设备厂商和品牌。

MIUI/HyperOS 没有公开、稳定的 API 可读取“自启动”和厂商“省电策略”开关。因此
界面必须把它们显示为“需要用户核对”，不能在跳转设置后直接宣称已经开启。

## 状态模型

| 状态 | 条件 | UI |
|:--|:--|:--|
| `RESTRICTED` | Android 明确报告后台受限 | 错误色提示，优先进入应用设置 |
| `ATTENTION` | 电池优化未豁免、standby bucket 受限，或 Xiaomi 系需要核对 OEM 开关 | 显示后台保护卡片和操作入口 |
| `READY` | 非强限制 ROM，且公开状态未发现限制 | 默认不打扰用户 |

Xiaomi 系设备即使已通过标准电池优化豁免，仍显示一条低强度核对提示，因为厂商
自启动与后台省电状态不可读取。

## 设置入口

按用户点击后依次尝试：

1. MIUI/HyperOS 自启动：
   `miui.intent.action.OP_AUTO_START`；
2. MIUI/HyperOS 省电策略：
   `miui.intent.action.POWER_HIDE_MODE_APP_LIST`；
3. Android 电池优化列表：
   `Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`；
4. Veer 应用详情：
   `Settings.ACTION_APPLICATION_DETAILS_SETTINGS`。

每个 Intent 都在启动时捕获 `ActivityNotFoundException` 和 `SecurityException`；
厂商页面不存在时自动回退到 Android 标准设置，不让操作变成死按钮。

## 首页交互

- 卡片位于连接概览之后、主连接按钮之前，风险信息与连接操作保持邻近。
- 首行显示当前结论，不展示虚假的百分比或“自动修复”。
- 展开后列出检测到的公开状态和 MIUI/HyperOS 两项人工核对要求。
- 提供“电池与后台设置”“自启动设置”“应用详情”三个显式按钮。
- Activity 回到前台时重新检测公开状态。

## 验收

自动化：

- 纯策略测试覆盖受限、Xiaomi 核对、电池优化、standby bucket 和正常状态。
- Intent 构建测试确保标准回退带正确 package URI。
- `testDebugUnitTest`、`lintDebug`、Debug/Release 构建通过。

真机：

- HyperOS 设备识别为 Xiaomi 系。
- 自启动 Intent 解析到系统安全中心。
- 省电 Intent 解析到系统电量管理。
- 标准设置入口均存在；无法解锁时只验证解析和启动安全性，不把人工开关结果标记
  为通过。

## 2026-07-30 执行结果

- 新增纯策略层、Android 公开状态采集、MIUI/HyperOS 设置导航和首页
  “后台运行保护”卡片。
- Activity 每次回到前台都会重新检测，不缓存设置前的结果。
- HyperOS 真机读取结果为：
  - OEM：Xiaomi；
  - 风险：`ATTENTION`；
  - 标准电池优化已豁免；
  - Android 未报告后台活动受限；
  - 系统未开启全局省电模式；
  - 厂商自启动/省电开关继续明确标记为“需要用户核对”。
- 自启动、省电策略和应用详情三个 Intent 均由真机系统成功解析并启动。
- 单元测试、Android Lint、Debug APK 与 R8 Release APK 全部通过。
- Compose 交互测试增加了交互屏幕前置规则：设备处于锁屏/Dozing 时在 Compose
  rule 创建前明确跳过，避免测试永远等待窗口焦点。本轮真机在 38 ms 内按该原因
  跳过；解锁后的文本、展开和三个按钮仍需人工/仪器测试确认。
