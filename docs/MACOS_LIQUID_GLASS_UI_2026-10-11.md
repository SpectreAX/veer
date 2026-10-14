# macOS Liquid Glass 界面改造

用户参考：[ProjectClash/Clash-Client](https://github.com/ProjectClash/Clash-Client) 与提供的 macOS 截图。仅研究导航、布局与视觉层级，不复制其源码、商标或 VPN 功能。

## 实施范围

- 系统 NavigationSplitView 侧边栏：AI 工作台、规则稿、策略组、AI 设置。页面切换不清空草稿或候选，也不取消请求。
- 工作台保留双栏任务关系；表单、规则、预览拆成留白充分的实底分区。独立页面复用相同编辑控件，不维护第二份状态。
- Veer 绿色强调、SF Symbols、系统字体和语义色；AI 地址与模型增加持久可见标签。
- macOS 26+ 使用公开 `glassEffect(.regular)` 与 `.glassProminent`，导航和工具栏由原生系统呈现。内容层不叠加玻璃，避免文字混色与嵌套 glass。
- macOS 14–25 使用 material / borderedProminent 回退。Reduce Transparency 使用实底和普通主按钮；无自定义位移/动画，无新增网络或密钥访问。
- 不增加连接状态、启动按钮、VPN、订阅读取或完整配置导入；确认仍仅修改 rules 草稿。

## 验证门禁

编译与原有 9 项 Swift 测试；原生页面导航、输入与预览、确认/撤销、Key 状态；浅色/深色、长出口和最小窗口画面；独立终审及设计文档刷新。旧系统回退只能在本机编译检查，需旧系统设备补充实测。

## 来源

- [ClashMacRootView](https://github.com/ProjectClash/Clash-Client/blob/main/apple/ClashMacClient/Sources/ClashMacClient/ClashMacRootView.swift)：侧边导航与 macOS shell。
- [Apple：Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)：系统组件与内容/控制层原则。
- [Apple：glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))：公开原生效果，SDK 标明 macOS 26 起可用。

## 实施验证记录

- release 编译/ad-hoc 签名与 9 项 Swift Testing 全部通过；一次机械 UI 扫描为 `[]`。
- macOS 27.2 实际运行、浅色 1120×860 恢复窗口：侧边导航、独立设置页、中文指令与本地 10 条多服务分流预览。设置页只显示保存状态，SecureField 为空，未读取或重新保存真实 Key。
- 切换设置再返回后候选仍存在；展开 YAML Diff 正确。确认后独立规则页显示同一份 10 条规则，工具栏撤销恢复 `rules: []`。
- 截图：`native/macos/artifacts/liquid-workbench.png`、`liquid-settings.png`、`liquid-review.png`。图片在 Git 中忽略，不是导入的真实用户配置。
- 当前没有深色、精确最小窗口 1080×700、完整 VoiceOver、Reduce Transparency 和旧 OS 实测证据；未更改全局设置。源码采用原生语义色与可用性回退，不把编译通过当作这些运行验证。
- 未重测真实 API 或实际导出文件；本轮修改界面层，不改变 AI 请求、规则生成、持久 Key 或导出协议。
- 独立终审发现 Diff 的亮绿色正文对比度不足，已将差异全文改为系统 primary 正文色，保留 `+ / −` 增删标记。重新编译签名与 9 项测试通过，重现相同 10 项候选并留存 `liquid-review-fixed.png`。
- 设计流程直接采用用户指定项目和截图为参考，没有随机方向、seed key 或另行生成三份概念图；不伪造这些流程证据。
- 修复后独立终审结论：`ship`。唯一 material finding 为 resolved；partial 0、unresolved 0。此结论针对已审阅的浅色原生页面，不代表完整发布认证。

## 后续局部调整：按钮、Toast 与顶栏

根据用户三张截图：撤销/检查/导出移至页面标题右侧并使用 `.glass` 辅助按钮，隐藏窗口重复标题并移除标题区装饰徽标。底部提示改为不占布局高度的浮层，普通消息 4 秒、错误 8 秒，忙碌提示不自动消失，支持手动关闭。按消息代次取消旧计时，重复同一消息也重启生命周期。

验证：本机 release 构建签名/启动成功，原 9 项测试及新 2 项提示状态测试共 11 项通过；CUA 实测检查提示出现，4.5 秒后从可访问性树移除；截图 `native/macos/artifacts/glass-buttons-toast.png` 确认玻璃按钮、无重复顶栏标题、无常驻提示。错误 8 秒和忙碌不消失的完整 UI 路径未独立实测，状态保护已有单元测试。旧系统与辅助功能限制不变。
