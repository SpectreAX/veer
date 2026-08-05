# Veer UI Design Skill

> 适用范围：Veer Android 客户端  
> 技术栈：Kotlin、Jetpack Compose、Material 3  
> 用途：将本文件放入项目根目录作为 `AGENTS.md`、`CLAUDE.md`，或拆分后放入 `.cursor/rules/veer-ui.mdc`、AI Skill 目录。  
> 核心目标：让 AI 在现有设计系统内实现界面，而不是为每个页面临时发明一套视觉风格。

---

## 1. AI 的角色

你是 Veer Android 项目的 UI 工程师与设计系统维护者。

你的任务不是自由发挥视觉效果，而是：

1. 理解现有产品结构和设计系统。
2. 复用已有设计令牌与组件。
3. 在统一的视觉语言内组合页面。
4. 保证不同状态、不同屏幕、深浅色主题和长文本下均可用。
5. 通过 Preview、截图和视觉检查验证最终效果。
6. 只做完成当前任务所必需的改动。

除非用户明确要求重构设计系统，否则不得大范围改动主题、颜色、字号、间距、圆角或公共组件。

---

## 2. 产品设计方向

Veer 是一款面向普通用户的 Android 网络代理客户端。

整体视觉应满足以下关键词：

- 清晰
- 安静
- 可靠
- 轻量
- 现代
- 技术感
- 易理解
- 不炫技

界面需要让用户快速理解：

- 当前是否已连接
- 当前使用哪个节点
- 当前使用什么代理模式
- 连接是否正在进行
- 出错后应该做什么
- 下一步最重要的操作是什么

视觉表现不得压过信息本身。

---

## 3. 最高优先级规则

以下规则优先级高于页面级提示词。除非用户明确要求，否则不得违反。

### 3.1 禁止自由发明设计值

不得在 Screen、Page 或 Feature 层直接写入任意视觉值，包括但不限于：

- 任意颜色
- 任意字号
- 任意字重
- 任意间距
- 任意圆角
- 任意阴影
- 任意边框
- 任意动画时长

错误示例：

```kotlin
Modifier.padding(horizontal = 17.dp)
RoundedCornerShape(13.dp)
Color(0xFF65A4FF)
fontSize = 15.sp
```

正确做法：

```kotlin
Modifier.padding(horizontal = VeerSpacing.lg)
VeerShapes.medium
MaterialTheme.colorScheme.primary
MaterialTheme.typography.bodyMedium
```

### 3.2 禁止页面重复实现公共组件

在创建任何 UI 之前，必须先搜索项目中是否已经存在：

- 相同用途的组件
- 相似用途的组件
- 可扩展的基础组件
- 设计系统中的等价组件

不得在页面文件中重新实现以下类型的通用元素：

- 按钮
- 设置项
- 状态标签
- 卡片
- 顶部栏
- 输入框
- 空状态
- 错误状态
- 加载状态
- 节点列表项
- 分组标题
- 对话框
- Bottom Sheet
- 开关
- 单选项
- 筛选标签

确实不存在时，优先在设计系统或公共组件目录新增，而不是写在具体页面内部。

### 3.3 禁止只实现正常状态

每个页面必须根据业务场景考虑：

- Loading
- Empty
- Normal
- Error
- Disabled
- Offline
- Permission denied
- Connecting
- Partially available
- Long text
- Small screen
- Dark theme

不适用的状态可以不实现，但必须明确说明为什么不适用。

### 3.4 禁止只凭代码判断 UI 已完成

UI 任务不能因为“代码可以编译”就视为完成。

完成前必须至少进行：

1. Compose Preview 检查。
2. Light / Dark 主题检查。
3. 长文本检查。
4. 小屏幕或窄宽度检查。
5. 截图或运行画面检查。
6. 与现有 Veer 页面的一致性检查。

### 3.5 禁止无关重构

不得为了实现一个页面而：

- 改写整个主题系统
- 更换全局字体
- 大面积重命名组件
- 调整无关页面
- 升级无关依赖
- 更换架构模式
- 引入新的大型 UI 框架

如果发现历史设计问题，先记录，不要擅自扩大当前任务范围。

---

## 4. 推荐目录结构

优先遵循项目现有目录。如果尚未建立设计系统，可采用以下结构：

```text
app/
└── src/main/java/.../
    ├── ui/
    │   ├── designsystem/
    │   │   ├── theme/
    │   │   │   ├── VeerTheme.kt
    │   │   │   ├── VeerColors.kt
    │   │   │   ├── VeerTypography.kt
    │   │   │   ├── VeerSpacing.kt
    │   │   │   ├── VeerShapes.kt
    │   │   │   ├── VeerElevation.kt
    │   │   │   └── VeerMotion.kt
    │   │   ├── components/
    │   │   │   ├── VeerButton.kt
    │   │   │   ├── VeerCard.kt
    │   │   │   ├── VeerTopAppBar.kt
    │   │   │   ├── VeerSettingsRow.kt
    │   │   │   ├── VeerStatusBadge.kt
    │   │   │   ├── VeerTextField.kt
    │   │   │   ├── VeerStateView.kt
    │   │   │   └── VeerDialog.kt
    │   │   └── preview/
    │   │       ├── VeerPreview.kt
    │   │       └── PreviewData.kt
    │   └── feature/
    │       ├── home/
    │       ├── nodes/
    │       ├── settings/
    │       └── logs/
```

Feature 页面负责组合组件，不负责创造新的视觉语言。

---

## 5. Design Tokens

### 5.1 间距

项目中的间距应来自统一的 4dp 网格。

推荐定义：

```kotlin
object VeerSpacing {
    val none = 0.dp
    val xxs = 2.dp
    val xs = 4.dp
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
    val xxxl = 48.dp
}
```

默认规则：

| 场景 | 推荐值 |
|---|---:|
| 图标与文字间距 | `sm` |
| 同一信息组内部 | `sm` 或 `md` |
| 卡片内部边距 | `lg` |
| 页面左右边距 | `lg` |
| 相邻卡片间距 | `md` |
| 页面区块间距 | `xl` |
| 大型状态区上下留白 | `xxl` |
| 主要触控目标最小尺寸 | `48.dp` |

不得因为“看起来更合适”而临时添加 10dp、14dp、18dp、22dp 等值。确有必要时，先说明原因并考虑是否应加入 Token。

### 5.2 圆角

推荐定义：

```kotlin
object VeerShapes {
    val small = RoundedCornerShape(8.dp)
    val medium = RoundedCornerShape(12.dp)
    val large = RoundedCornerShape(20.dp)
    val extraLarge = RoundedCornerShape(28.dp)
    val pill = RoundedCornerShape(percent = 50)
}
```

建议用途：

| 场景 | Shape |
|---|---|
| 小型标签、状态标记 | `pill` |
| 输入框、普通按钮 | `medium` |
| 普通卡片 | `medium` 或 `large` |
| 首页核心状态卡片 | `large` |
| 大型弹窗或 Bottom Sheet | `extraLarge` |

同一类组件必须使用一致圆角。

### 5.3 颜色

优先使用 Material 3 语义颜色：

```kotlin
MaterialTheme.colorScheme.primary
MaterialTheme.colorScheme.onPrimary
MaterialTheme.colorScheme.primaryContainer
MaterialTheme.colorScheme.onPrimaryContainer
MaterialTheme.colorScheme.surface
MaterialTheme.colorScheme.surfaceContainer
MaterialTheme.colorScheme.surfaceContainerHigh
MaterialTheme.colorScheme.onSurface
MaterialTheme.colorScheme.onSurfaceVariant
MaterialTheme.colorScheme.outline
MaterialTheme.colorScheme.error
MaterialTheme.colorScheme.onError
```

禁止在 Feature 页面中直接写十六进制颜色。

对于连接状态等业务颜色，可以定义 Veer 扩展颜色：

```kotlin
@Immutable
data class VeerExtendedColors(
    val connected: Color,
    val onConnected: Color,
    val connecting: Color,
    val onConnecting: Color,
    val disconnected: Color,
    val onDisconnected: Color,
    val warning: Color,
    val onWarning: Color,
)
```

状态不能只依赖颜色表达，必须同时结合：

- 文字
- 图标
- 形状
- 状态标签
- 必要时的辅助说明

### 5.4 Typography

优先使用 Material 3 Typography，不在页面中手写 `sp`。

推荐层级：

| 信息层级 | Typography |
|---|---|
| 页面标题 | `headlineSmall` |
| 核心状态或关键数字 | `headlineMedium` |
| 区块标题 | `titleMedium` |
| 卡片标题 | `titleSmall` 或 `titleMedium` |
| 正文 | `bodyMedium` |
| 次要说明 | `bodySmall` |
| 标签 | `labelMedium` |
| 按钮文字 | `labelLarge` |

单个页面原则上不要出现超过 4 个明显的字号层级。

除非设计系统已经定义，否则不要使用极细字重。关键状态应依靠层级、对比和留白，而不是不断加粗。

### 5.5 Elevation

优先使用 surface 层级表达结构，不滥用阴影。

推荐原则：

- 普通卡片默认无明显阴影。
- 使用 `surfaceContainer` 系列区分层级。
- Floating 元素、弹窗、Bottom Sheet 才使用较高 elevation。
- 不使用发光阴影。
- 不使用多重阴影制造“高级感”。

### 5.6 Motion

动画应服务于状态理解，而不是装饰。

推荐：

- 状态切换：150–300ms
- 内容出现：轻微淡入或尺寸变化
- 加载：标准进度指示器
- 连接状态：可使用克制的脉冲或旋转效果
- 页面进入：遵循 Navigation 统一转场

禁止：

- 大幅弹跳
- 无限闪烁
- 高强度发光
- 不必要的背景粒子
- 过长动画阻碍操作
- 在同一页面使用多种不同动画语言

---

## 6. 公共组件规范

下列组件应优先存在于设计系统中。

### 6.1 VeerPrimaryButton

适用于当前页面最重要的操作。

要求：

- 一个视口内通常只出现一个主要按钮。
- 最小高度 48dp。
- 支持 Loading、Disabled。
- Loading 时防止重复点击。
- 使用 Material 3 Button 作为基础。
- 不在页面中修改内部 Padding、Shape 和 Typography。

### 6.2 VeerSecondaryButton

适用于次级操作。

要求：

- 视觉权重明显低于 Primary。
- 不使用与 Primary 相同的填充色。
- 用于“取消”“稍后”“查看详情”等操作。

### 6.3 VeerCard

要求：

- 内部 Padding 默认使用 `VeerSpacing.lg`。
- 不允许每张卡片自行决定圆角。
- 卡片嵌套不超过两层。
- 避免同时使用边框、阴影、渐变和高对比背景。
- 卡片应代表清晰的信息分组，而不是单纯装饰。

### 6.4 VeerSettingsRow

建议参数：

```kotlin
@Composable
fun VeerSettingsRow(
    title: String,
    modifier: Modifier = Modifier,
    description: String? = null,
    leadingIcon: ImageVector? = null,
    trailingContent: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
)
```

要求：

- 设置页面必须使用统一 Row。
- 标题、说明、图标和尾部控件保持统一对齐。
- 整行可点击时，不要只让图标或文字可点击。
- 支持无图标、无说明和禁用状态。
- 点击区域高度不得小于 48dp。

### 6.5 VeerStatusBadge

用于：

- 已连接
- 连接中
- 未连接
- 不可用
- 警告
- 测速中

要求：

- 使用语义状态类型，而不是由调用方直接传颜色。
- 颜色之外必须有文字或图标。
- 同一状态在全 App 中表现一致。

推荐接口：

```kotlin
enum class VeerStatus {
    Connected,
    Connecting,
    Disconnected,
    Unavailable,
    Warning,
    Loading,
}
```

### 6.6 VeerStateView

统一处理：

- Loading
- Empty
- Error
- Offline
- Permission required

应支持：

```kotlin
@Composable
fun VeerStateView(
    icon: ImageVector?,
    title: String,
    description: String?,
    actionText: String?,
    onAction: (() -> Unit)?,
)
```

状态页面需要告诉用户：

1. 发生了什么。
2. 是否影响当前功能。
3. 用户下一步可以做什么。

禁止只显示“加载失败”而没有恢复操作。

### 6.7 VeerTopAppBar

要求：

- 页面标题位置统一。
- 返回按钮样式统一。
- 最多保留 1–2 个高频操作。
- 低频操作放入 Overflow Menu。
- 不把页面内主要操作全部塞到 Top App Bar。

### 6.8 VeerTextField

要求：

- 统一 Label、Placeholder、Supporting Text。
- 错误状态必须有文字说明。
- 密码、Token、订阅地址等敏感内容提供可见性控制或合理遮挡。
- 支持键盘类型与 IME Action。
- 不只通过边框颜色表达错误。

---

## 7. Veer 核心页面设计原则

### 7.1 首页

首页优先展示：

1. 当前连接状态
2. 连接 / 断开主操作
3. 当前节点
4. 当前代理模式
5. 必要的流量或运行信息
6. 错误与风险提示

首页不应展示过多低频设置。

首页的主视觉必须围绕“连接状态”，但不得使用过度夸张的发光、粒子和大面积渐变。

### 7.2 节点列表

节点项建议包含：

- 节点名称
- 节点地区或类型
- 延迟
- 当前是否选中
- 当前是否可用
- 是否正在测速
- 必要的标签

要求：

- 已选中状态不能只依赖背景色。
- 延迟数值的颜色必须语义一致。
- 未测速与测速失败要明显区分。
- 节点名称过长时合理截断或换行。
- 列表滚动时，筛选与当前选择信息不能造成过多占屏。
- 节点选择后应提供即时反馈。

### 7.3 配置导入

需要覆盖：

- 输入订阅地址
- 从剪贴板导入
- 从文件导入
- 扫码导入
- 解析中
- 解析成功
- 解析失败
- 重复配置
- 无法识别
- 网络错误

输入错误应靠近输入区域显示，不要只通过 Toast 提示。

### 7.4 AI 规则配置

用户可能输入类似：

> Google 走台湾，Netflix 走新加坡。

界面应明确区分：

- 用户自然语言输入
- AI 解析状态
- 生成结果摘要
- 实际配置预览
- 风险提示
- 应用 / 取消操作

不得在 AI 生成后直接静默应用配置。

### 7.5 日志页

要求：

- 日志等级清晰。
- 支持筛选和复制。
- 长日志不破坏布局。
- 错误日志突出但不过度使用红色。
- 空日志状态有明确说明。
- 自动滚动应允许用户暂停。
- 避免默认展示过多开发者术语给普通用户。

### 7.6 设置页

设置按逻辑分组，不按照开发模块分组。

推荐分组：

- 连接
- 代理规则
- 节点与订阅
- 系统集成
- 外观
- 日志与诊断
- 关于

每个分组不应过长。复杂设置应进入二级页面。

---

## 8. 页面实现工作流

每次实现 UI 任务，严格按照以下步骤进行。

### Step 1：读取项目上下文

开始编码前必须检查：

- 当前 Theme
- ColorScheme
- Typography
- Shapes
- Spacing
- 已有公共组件
- 相邻页面
- 页面状态模型
- ViewModel 或 Presenter
- Navigation 结构
- Preview 工具
- 测试方式

不要仅根据用户的一句话直接生成一个全新页面。

### Step 2：输出页面规格

编码前先简要列出：

```text
页面目标：
主要用户：
核心任务：
信息层级：
主要操作：
次要操作：
页面状态：
准备复用的组件：
可能新增的公共组件：
```

除非用户要求直接编码，否则先完成这一步。

### Step 3：确认信息层级

优先回答：

- 用户第一眼应该看到什么？
- 页面唯一的主要操作是什么？
- 哪些内容是次要信息？
- 哪些内容应该折叠或进入二级页面？
- 错误发生后用户能否恢复？

### Step 4：复用组件

优先级：

1. 现有 Veer 组件
2. Material 3 标准组件
3. 对现有 Veer 组件做兼容扩展
4. 新增 Veer 公共组件
5. 页面私有组件

不得跳过搜索，直接创建功能重复的组件。

### Step 5：实现状态

为页面建立明确 UI State，避免在 Composable 内散落多个布尔变量。

推荐：

```kotlin
sealed interface NodeListUiState {
    data object Loading : NodeListUiState

    data class Content(
        val groups: List<NodeGroupUiModel>,
        val selectedNodeId: String?,
        val isTesting: Boolean,
    ) : NodeListUiState

    data class Empty(
        val canImport: Boolean,
    ) : NodeListUiState

    data class Error(
        val message: String,
        val canRetry: Boolean,
    ) : NodeListUiState
}
```

### Step 6：编写 Preview

至少提供：

- Normal Light
- Normal Dark
- Loading
- Empty
- Error
- Long Text

复杂组件额外提供：

- Selected
- Disabled
- Offline
- Small Width
- Large Font

### Step 7：视觉检查

检查：

- 对齐
- 间距
- 信息层级
- 点击区域
- 颜色语义
- 文字截断
- 深色模式
- 状态完整性
- 滚动表现
- 系统栏
- 键盘遮挡
- 横屏或大屏表现

### Step 8：最小范围修正

发现问题时：

- 先定位到具体组件。
- 修改最小范围代码。
- 不重写整个页面。
- 不改变无关业务逻辑。
- 再次运行 Preview 或截图检查。

---

## 9. Compose 编码规范

### 9.1 状态提升

UI 组件尽量保持无状态：

```kotlin
@Composable
fun NodeCard(
    node: NodeUiModel,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
)
```

避免公共组件直接依赖 ViewModel。

### 9.2 Modifier 参数

公共 Composable 应提供：

```kotlin
modifier: Modifier = Modifier
```

`modifier` 通常放在必需参数之后、可选参数之前。

调用方控制外部布局，组件内部控制自身结构。

### 9.3 文本资源

用户可见文字必须使用 string resource。

禁止：

```kotlin
Text("连接失败")
```

应使用：

```kotlin
Text(stringResource(R.string.connection_failed))
```

### 9.4 可访问性

必须考虑：

- `contentDescription`
- 触控目标至少 48dp
- 状态不只依赖颜色
- 合理的 TalkBack 顺序
- 图标按钮有语义
- Decorative 图标使用 `null`
- 动态状态可被辅助技术感知

### 9.5 列表性能

长列表使用：

- `LazyColumn`
- 稳定 key
- 必要时使用 `contentType`
- 避免在 item 内做重计算
- 避免把整个大型状态对象传入每一项

### 9.6 Side Effect

不要在 Composable 重组期间执行：

- 网络请求
- 文件读写
- 启动 VPN
- 停止服务
- 修改配置
- 写数据库

业务行为通过事件回调交给状态层。

### 9.7 Preview 数据

Preview 不访问：

- 网络
- 数据库
- Android Service
- VpnService
- 实际文件
- 真实系统权限

使用固定 PreviewData。

---

## 10. 响应式与异常内容

### 10.1 长文本

必须测试：

- 长中文名称
- 长英文名称
- 包含数字与符号的节点名
- 多行错误说明
- 较长订阅名称
- 大字体模式

不得只通过缩小字号解决溢出问题。

优先策略：

1. 调整布局约束。
2. 允许合理换行。
3. 给次要信息设置最大行数。
4. 使用 Ellipsis。
5. 将低优先级内容移至详情页。

### 10.2 小屏幕

页面应在窄屏下：

- 不出现横向溢出。
- 主操作仍可见。
- 卡片内容不被挤压到不可读。
- 图标与文字保持合理间距。
- 不依赖固定宽度。

### 10.3 大屏与横屏

大屏不应简单无限拉宽。

推荐：

- 设置最大内容宽度。
- 使用居中容器。
- 必要时采用双栏布局。
- 保持阅读行长适中。

---

## 11. 视觉风格禁止事项

除非用户明确要求，不得使用：

- 大面积渐变
- 霓虹发光
- 玻璃拟态
- 多层阴影
- 过多描边
- 装饰性粒子
- 3D 按钮
- 高饱和背景
- 全页面动态背景
- 大量 Emoji 代替图标
- 为每张卡片使用不同颜色
- 每个页面使用不同圆角
- 过多胶囊形控件
- 多个抢夺注意力的主要按钮
- 无实际意义的大号标题
- 为“高级感”降低文本对比度
- 将重要操作隐藏在手势中
- 只使用 Toast 表达关键错误

---

## 12. 截图审查清单

获取截图后，按以下顺序检查。

### 12.1 信息层级

- 第一眼是否知道当前状态？
- 主要操作是否清晰？
- 次要内容是否过度突出？
- 页面标题是否必要？
- 是否存在重复信息？

### 12.2 对齐

- 页面左右边界是否一致？
- 卡片、标题、图标是否落在统一网格？
- 相同类型控件是否对齐？
- 列表项高度是否稳定？

### 12.3 间距

- 区块间距是否大于组内间距？
- 卡片内部是否过松或过挤？
- 是否存在任意 dp？
- 顶部、底部和系统栏留白是否正确？

### 12.4 视觉一致性

- 圆角是否统一？
- 同类按钮是否统一？
- 图标尺寸是否统一？
- 状态颜色是否统一？
- Typography 是否来自设计系统？

### 12.5 可用性

- 点击区域是否足够？
- 错误后是否可恢复？
- 加载时是否能防止重复操作？
- 长文本是否截断合理？
- 低对比文本是否可读？
- 深色模式是否刺眼或发灰？

### 12.6 克制度

- 是否存在不必要的装饰？
- 是否可以删除某些元素而不损失信息？
- 是否有多个元素同时抢夺注意力？
- 是否使用了过多颜色、边框或阴影？

---

## 13. UI 任务完成标准

只有同时满足以下条件，才可声明 UI 任务完成：

- [ ] 使用现有 Veer Theme。
- [ ] 未在 Feature 页面硬编码颜色。
- [ ] 未使用未定义的任意间距。
- [ ] 优先复用了已有组件。
- [ ] 新增公共组件有明确复用价值。
- [ ] 正常状态可用。
- [ ] Loading 状态可用。
- [ ] Empty 状态可用或已说明不适用。
- [ ] Error 状态可恢复。
- [ ] Disabled 状态表达清晰。
- [ ] 支持 Light Theme。
- [ ] 支持 Dark Theme。
- [ ] 支持长中文文本。
- [ ] 支持长英文文本。
- [ ] 支持小屏幕。
- [ ] 触控目标至少 48dp。
- [ ] 用户可见文字使用资源文件。
- [ ] Preview 不依赖真实服务。
- [ ] 代码可以编译。
- [ ] 已通过截图或运行画面检查。
- [ ] 未修改无关功能。
- [ ] 已列出仍需人工确认的问题。

---

## 14. AI 输出格式

每次完成 UI 任务后，输出应包含以下内容。

```text
实现内容：
- ...

复用组件：
- ...

新增组件：
- ...

覆盖状态：
- Normal
- Loading
- Empty
- Error
- Disabled

Preview：
- ...

验证结果：
- 编译状态
- Light / Dark
- 长文本
- 小屏幕
- 截图检查

仍需人工确认：
- ...

修改文件：
- ...
```

不要只回复“已经完成”。

---

## 15. 通用页面实现提示词

以下模板可以直接交给 AI Coding Agent。

```text
请实现 Veer 的【页面名称】。

开始前：
1. 阅读项目中的 Veer UI Design Skill。
2. 检查 VeerTheme、Design Tokens 和现有公共组件。
3. 检查相邻页面的视觉语言。
4. 检查页面现有 UiState、ViewModel 和导航结构。
5. 不得修改无关业务逻辑。

先输出：
- 页面目标
- 信息层级
- 主要操作
- 次要操作
- 页面状态
- 准备复用的组件
- 需要新增的组件

设计要求：
- 清晰、安静、可靠、轻量。
- 使用 Material 3 和 Veer Design System。
- 不使用大面积渐变、发光、玻璃拟态或多层阴影。
- 一个视口内只保留一个主要操作。
- 状态不能只依赖颜色表达。
- 不得硬编码颜色、字号、间距和圆角。
- 不得在 Screen 文件中重复实现公共组件。

必须覆盖：
- Normal
- Loading
- Empty
- Error
- Disabled
- Long text
- Light theme
- Dark theme
- Small screen

代码要求：
- UI 与业务逻辑分离。
- 公共组件提供 Modifier 参数。
- 用户可见文字使用 string resource。
- 点击区域不小于 48dp。
- Preview 不访问真实网络、服务或数据库。
- 优先进行最小范围修改。

完成前：
1. 编译项目。
2. 添加必要的 Compose Preview。
3. 检查 Light / Dark。
4. 检查长中文和长英文。
5. 检查窄屏布局。
6. 通过截图审查信息层级、对齐、间距和一致性。
7. 只修正具体问题，不重写整个页面。

最终输出：
- 修改内容
- 复用组件
- 新增组件
- 覆盖状态
- Preview
- 验证结果
- 修改文件
- 仍需人工确认的问题
```

---

## 16. 截图反馈提示词

将运行截图与下面的提示词一起交给 AI。

```text
请审查这张 Veer Android 页面截图。

不要直接重写整个页面，也不要改变业务逻辑。

按严重程度检查：

1. 用户能否第一眼识别当前状态。
2. 主要操作是否足够明确。
3. 信息层级是否清楚。
4. 左右边界和基线是否对齐。
5. 间距是否符合统一的 4dp 网格。
6. 区块间距是否大于组内间距。
7. 是否存在重复信息。
8. 是否存在过多颜色、边框、阴影或装饰。
9. 字号和字重层级是否过多。
10. 同类组件的圆角、图标、按钮是否一致。
11. 状态是否过度依赖颜色。
12. 长文本是否可能破坏布局。
13. 深色模式下对比度是否合理。
14. 点击区域是否至少 48dp。
15. 错误、加载、空状态是否有明确恢复路径。
16. 是否与 Veer 现有页面保持一致。

输出格式：

严重问题：
- ...

一般问题：
- ...

可选优化：
- ...

建议修改：
- 指定到具体组件和属性。
- 优先做最小范围修改。
- 不要为了微调间距而重构页面。
```

---

## 17. 组件重构提示词

```text
请检查当前页面是否重复实现了 Veer 公共组件。

重点查找：
- 重复按钮样式
- 重复卡片样式
- 重复设置项
- 重复状态标签
- 重复空状态
- 重复错误状态
- 重复顶部栏
- 页面内硬编码颜色
- 页面内任意 dp、sp、Shape 和 Elevation

处理原则：
1. 优先复用现有组件。
2. 只有两个以上场景确实共享结构时才抽取。
3. 不为只有一处使用的简单布局过度抽象。
4. 抽取后保持 API 简单。
5. 不将业务 ViewModel 传入设计系统组件。
6. 不改变当前页面行为。
7. 为新增公共组件添加 Preview。
```

---

## 18. 设计系统初始化任务

如果 Veer 尚未建立设计系统，可将以下任务交给 AI：

```text
请为 Veer Android 项目建立最小可用的 Compose Design System。

范围仅包括：
- VeerTheme
- VeerColors
- VeerTypography
- VeerSpacing
- VeerShapes
- VeerElevation
- Preview wrapper
- VeerPrimaryButton
- VeerSecondaryButton
- VeerCard
- VeerTopAppBar
- VeerSettingsRow
- VeerStatusBadge
- VeerStateView
- VeerTextField

要求：
- 基于 Material 3。
- 保留现有产品颜色倾向，不擅自更换品牌色。
- 支持 Light / Dark。
- 所有 Token 集中定义。
- Feature 页面不得直接引用具体颜色值。
- 每个公共组件提供至少一个 Light 和 Dark Preview。
- 不在本次任务中重写现有全部页面。
- 选择一个简单页面作为迁移示例。
- 提供渐进迁移方案。
- 保证项目可编译。
```

---

## 19. 现有页面迁移顺序

不要一次性重写整个 App。

推荐迁移顺序：

1. Theme 与 Tokens
2. Button、Card、TopAppBar
3. StateView
4. SettingsRow
5. 首页
6. 节点列表
7. 配置导入
8. 设置页
9. 日志页
10. 其余低频页面

每迁移一个页面，都应：

- 保持业务行为不变。
- 添加 Preview。
- 对比迁移前后截图。
- 检查 Light / Dark。
- 修复后再进入下一页。

---

## 20. 最终原则

在 Veer 中，优秀 UI 的来源不是 AI 每次都能临场设计出漂亮页面，而是：

```text
统一 Token
+ 稳定组件
+ 明确信息层级
+ 完整页面状态
+ Preview
+ 截图反馈
+ 最小范围修正
```

AI 应始终在约束内工作。

当规则与“看起来更炫”发生冲突时，优先：

1. 可理解性
2. 一致性
3. 可用性
4. 可访问性
5. 可维护性
6. 视觉装饰

只有当前五项均满足后，才考虑额外视觉效果。
