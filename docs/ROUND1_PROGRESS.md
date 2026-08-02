# Veer 第 1 轮功能开发进度与下一步计划

> 更新于 2026-07-31

---

## 当前进度

### ✅ 三项功能代码已全部完成

| 功能 | 新建文件 | 修改文件 | 状态 |
|:--|:--|:--|:--|
| **活跃连接详情页** | `ui/connections/ConnectionsActivity.kt`<br>`ui/connections/ConnectionsViewModel.kt` | `MihomoRepository.kt`<br>`AndroidManifest.xml`<br>`MainActivity.kt` | ✅ 代码完成 |
| **首页实时流量图表** | `ui/chart/SpeedChartCanvas.kt` | `ConnectionStatusRepository.kt`<br>`MainActivity.kt` | ✅ 代码完成 |
| **节点体验优化** | — | `ui/nodes/NodesViewModel.kt`<br>`ui/nodes/NodesActivity.kt` | ✅ 代码完成 |

### ✅ 构建门禁全部通过

| 检查项 | 结果 |
|:--|:--|
| `lintDebug` | ✅ BUILD SUCCESSFUL |
| `testDebugUnitTest` | ✅ BUILD SUCCESSFUL |
| `assembleDebug` | ✅ BUILD SUCCESSFUL |

### 功能详情

#### 1. 活跃连接详情页

- `MihomoRepository` 新增 `ConnectionDetail` 数据类，包含 id、host、destinationIP、network、type、chains、rule、rulePayload、download、upload、start 字段
- 新增 `connectionDetails()` 方法解析 Mihomo `/connections` REST 端点的完整连接列表
- 新增 `closeConnection()` 和 `closeAllConnections()` 方法
- `ConnectionsViewModel` 支持搜索过滤（host/rule/chain）、三种排序模式（按流量/时长/域名）、每 2 秒自动刷新
- `ConnectionsActivity` 使用 Material 3 风格，含搜索栏、排序下拉、全部关闭按钮
- 首页新增"连接"快捷入口按钮

#### 2. 首页实时流量图表

- `ConnectionStatusRepository` 新增 `SpeedSample` 数据类和 `speedHistory: StateFlow<List<SpeedSample>>` 
- 60 秒环形缓冲，基于 1 秒 IPC 轮询的差值计算实时速率
- `SpeedChartCanvas.kt` 使用 Compose Canvas 绘制上传/下载双线实时折线图
- 自动 Y 轴缩放、线下半透明渐变填充、速率格式化标注
- 仅在 VPN 运行时展示

#### 3. 节点体验优化

- `NodesViewModel` 新增 `NodeSortMode` 枚举（默认/延迟/名称/地区）和 `NodeFilter` 数据类
- 支持地区筛选、隐藏不可用节点
- `NodesActivity` 新增 `FilterRow`（FilterChip 组合的排序/地区/可用性筛选栏）
- `NodeRow` 中的延迟文本替换为 `DelayBadge` 颜色指示器：
  - 🟢 ≤100ms 绿色
  - 🟡 100-300ms 黄色
  - 🔴 >300ms 或超时 红色
  - 灰色 未测速

---

## 待完成项

- [x] 模拟器端到端验证（VPN 运行时测试连接页数据正确性、图表更新、节点排序筛选）
- [x] `assembleRelease` R8 优化构建验证
- [x] 更新 `IMPLEMENTATION_STATUS.md` 和 `NEXT_STAGE_DEVELOPMENT_PLAN.md`

---

## 下一步计划

按照 `FEATURE_RECOMMENDATIONS.md` 的路线图，第 1 轮功能完成后的推进方向：

### 第 2 轮功能（建议接续开发）

| 优先级 | 功能 | 预估工作量 | 核心价值 |
|:--|:--|:--|:--|
| ⭐⭐⭐⭐⭐ | **AI 操作历史 + 快捷模板** | 3 天 | 释放 AI 引擎的完整用户价值，支持历史回放/重新执行/撤销 |
| ⭐⭐⭐⭐ | **独立设置页面** | 2 天 | 整合散落的配置入口（API Key、DNS、Per-App、后台保护等） |
| ⭐⭐⭐ | **深色模式手动切换** | 1 天 | 三档切换，简单但用户感知强 |

### 第 3 轮功能

| 优先级 | 功能 | 预估工作量 | 核心价值 |
|:--|:--|:--|:--|
| ⭐⭐⭐ | **字符串资源提取 (i18n)** | 2 天 | 将硬编码中文字符串迁移到 strings.xml，为国际化打基础 |
| ⭐⭐⭐⭐ | **导航架构统一（单 Activity）** | 3-4 天 | 消除页面切换白屏闪烁，统一 Compose Navigation |

### 持续改进项

| 功能 | 预估 | 说明 |
|:--|:--|:--|
| 规则管理增强（导入/导出/分组） | 3-4 天 | 根据用户反馈优先级调整 |
| 订阅管理优化（到期预警/配额进度条） | 2 天 | 提升订阅管理效率 |
| Rule Provider 管理界面 | 3 天 | 高级用户强需求 |
| 流量统计历史 | 3-4 天 | 按日/周/月聚合流量趋势 |
| 配置覆写编辑器 | 3 天 | 高级用户"专家模式" |
| 辅助功能 (Accessibility) | 1-2 天 | TalkBack 兼容 |
| GEO 数据库管理界面 | 1 天 | 设置页子项 |

### 跨 ROM 兼容性（并行推进）

| 待办 | 说明 |
|:--|:--|
| Pixel AOSP 基准验收 | 需 Pixel 实体设备 |
| ColorOS / OriginOS 兼容 | 需对应 OPPO/vivo 设备 |
| 8 小时锁屏功耗测试 | 需稳定网络环境 |
| x86_64 / armeabi-v7a 动态验收 | 需对应设备/模拟器 |

---

## 第 2 轮进度（2026-07-31）

### ✅ AI 操作历史 + 快捷模板已完成

- 每条指令持久化记录 profile、原始 prompt、解析来源、成功/失败结果和实际生成规则。
- 历史最多保留 100 条，文件位于应用私有目录且应用禁止系统备份；不保存 API Key。
- “再次执行”重新解析原 prompt，以当前订阅、节点健康和延迟为准，不回放过期计划。
- 撤销保存规则前后快照和策略组前后选择；执行前检查当前状态，后续修改存在时拒绝覆盖。
- 多步撤销使用事务式补偿：失败时尝试恢复撤销前状态，并关闭受影响旧连接。
- 输入框为空时展示 Netflix 日区、ChatGPT 美国、低延迟切换和网络诊断模板；点击仅填入输入框。

验证：

- 全量 Debug 单元测试 171/171，Lint、Debug APK、AndroidTest APK 全部通过。
- R8 `assembleRelease` 通过，生成未签名 Universal Release APK（约 250 MB）。
- HyperOS 真机完成 DIRECT→REJECT 链式历史测试：旧记录因冲突被拒绝，逆序撤销后精确恢复。
- 保数据 instrumentation 19 项正常结束；测试历史和临时规则已清理，原有 Netflix/OpenAI
  规则、VPN 与 OpenAI HTTPS 均正常。
- Android 16.1 arm64 模拟器导入最小测试配置后，VPN/Controller/互联网均为可用；连接页
  展示真实 host、规则链和流量，60 秒图表产生折线，节点筛选控件及 AI 模板/历史布局正常。

### ✅ 独立设置页面 + 深色模式手动切换已完成

- 新增独立设置页，集中管理 DeepSeek API Key、活动配置 DNS、应用分流、后台运行保护、
  外观和版本信息；设置页只负责持久化及导航，不持有 VPN/JNI 生命周期。
- API Key 编辑器从首页迁移到设置页；保存值继续使用 Android Keystore + AES-GCM，输入框
  不回显已有密钥。从设置返回首页时，AI 可用状态会在 `ON_RESUME` 立即刷新。
- 首页快捷操作重排为配置、AI 规则、节点、活跃连接、实时日志和设置，移除重复的 DNS、
  Per-App、后台保护及 API Key 编辑控件。
- 外观支持“跟随系统 / 浅色 / 深色”三档并持久化；所有现有 Activity 通过全局状态流即时
  接收主题变更，选择深色后返回首页仍保持深色。
- 设置页显示应用分流方向与已选应用数量；后台保护即使状态正常也会显示，便于主动检查。

验证：

- Debug 单元测试 175/175；Lint、Debug APK、AndroidTest APK 和 R8 Release 全部通过。
- Android 16.1 arm64 模拟器完整 instrumentation 20 项正常结束；新增设置 Compose 用例通过。
- 模拟器从主页进入设置页，六个分区、DNS/Per-App 状态和三档主题均完成可视检查；深色选择
  已验证跨 Activity 持久化。
- 模拟器临时保存测试 Key 后，私有存储中只出现 AES-GCM 密文；清除后无残留。
- HyperOS 真机保数据覆盖安装后恢复原 profile，Engine=Running；应用内诊断确认物理网络、
  VPN/TUN、Controller、DNS、规则、节点与代理出口全部 PASS。诊断测试历史已定向清理。

第 2 轮计划已全部完成。下一项：字符串资源提取（i18n 基础），随后统一单 Activity 导航。
