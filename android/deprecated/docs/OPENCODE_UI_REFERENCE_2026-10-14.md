# OpenCode v2 → Veer：参考研究与设计简报

## 证据范围

只读检出：`/tmp/veer-opencode-v2-reference-20261014`。
提交：`4617210822bdbb31e5749751afbfb4584ccedac8`，检出 HEAD 与远端 v2 一致。
参考应用包版本：`@opencode/app`、`@opencode/desktop` 均为 2.0.26。

本轮已读取源码、组件 stories 和样式声明，未安装或启动 OpenCode 桌面应用，未获取同提交真实应用截图。以下是源码证据与 Veer 设计提案，不是经过画面对比的 UI 克隆结论。

## 真实 UI 来源与可借鉴项

以下路径均相对参考仓库根目录，链接固定到同一提交，避免分支后续更新改变依据。

| 来源 | 观察到的实现 | Veer 适配提案 |
| --- | --- | --- |
| [session/screen.tsx](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/app/src/session/screen.tsx) | 对话与侧面板分区；独立审阅切换按钮；支持面板尺寸调整与窄屏路径 | 对话保持主区域，审阅区按需打开；不让很长的 Diff 挤掉对话 |
| [screen-layout.ts](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/app/src/session/screen-layout.ts) | 面板可用宽度、最小/最大宽度限制；审阅与 dock 是否并排由状态与宽度决定 | 宽窗口支持旁置审阅；窄窗口用单区域切换或原生 sheet，不简单缩小两列 |
| [session-composer-region.tsx](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/app/src/session/composer/session-composer-region.tsx) | 输入区位于时间线后面的独立 dock；请求/权限等状态由 controller 控制 | 固定底部输入；发送期间显示取消；仅迁移结构，不增加工具权限与队列能力 |
| [session-timeline-row.tsx](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/session-ui/src/timeline/session-timeline-row.tsx) | 分别渲染用户、助手、文件变更、错误/重试；披露状态可保存；工具记录与文本区分 | 将用户指令、真实步骤、修改摘要、文件差异分开；折叠状态按 turn 保留 |
| [file-changes.stories.tsx](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/session-ui/src/timeline/file-changes.stories.tsx) | 编辑准备/进行/完成分开；完成后显示 Diff；单/多文件以及重复修改有演示状态 | 未收到结果前不显示完成 Diff；文件条目点击打开审阅；每次候选对应自己的确认/撤销状态 |
| [session-review-v2.tsx](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/session-ui/src/v2/components/session-review-v2.tsx) 与 CSS | 审阅侧栏、过滤、折叠/展开、Diff 方式、文件导航；正文有独立滚动区域 | Veer 当前只有一份 rules 草稿，不搬入多文件树/过滤器；保留文件身份、单行代码、横向滚动与确认限制 |
| [oc-2.json](https://github.com/anomalyco/opencode/blob/4617210822bdbb31e5749751afbfb4584ccedac8/packages/ui/src/theme/themes/oc-2.json) | 声明浅深色主题、文字/边框/表面及 Diff 语义角色 | 借鉴中性层级，SwiftUI 仍用系统语义色；不把网页 hex 写死为 macOS 的系统颜色 |

`packages/app/package.json` 依赖 SolidJS；本提交的 desktop 使用 Electron。它们证明参考技术栈，不是 Veer 迁移到 Web/Electron 的理由。根 LICENSE 与 `packages/ui/LICENSE` 为 MIT。此次不复制源代码、字体文件、图标或商标；若后续直接复用，必须一并保留许可与归属。

## 设计简报（需要确认的构图）

模式：Operate。使用者希望安全完成分流修改，不希望理解 Git、终端或 Agent 工具。

- 未导入：保持现有中央玻璃加号与底部导入提示，不用 OpenCode 编程项目空态替代。
- 已导入：左侧保留配置导航；主区域是对话。宽窗口可在右侧打开「修改审阅」，窄窗口回到单列／原生 sheet。
- 对话正文默认呈现摘要与服务→出口，步骤可折叠；文件变更使用紧凑文件条目，点击展开完整 Diff 审阅。
- 底部保持解析模式、输入、发送／取消；导出与设置为辅助动作。
- 主确认动作只出现在当前可确认候选，不能确认旧结果；成功明确写“已确认到草稿，未应用到代理”。

成功标准：首次导入后用户能发出指令；可分清“准备/等待/结果/校验/待确认”与“已写入草稿”；可看到服务的明确出口并撤销当前修改。审阅打开/关闭、导航切换、外观切换均不得丢失候选和输入。

Thinking 只呈现真实应用阶段，不复制模型隐藏思维链。当前后端一次返回结果，因此不能伪造实时逐工具的 Agent 事件。原型可以演示合成状态，但必须标为演示，不连接 AI、不读取配置秘密。

## 首个可点击原型的状态清单

1. 未导入、导入 sheet、文件／URL 两种入口、导入失败与重试（使用合成示例）。
2. 已导入，无对话；模式明确区分本地／AI（原型均不发送请求）。
3. 用户指令、真实阶段形式的合成演示、处理中取消。
4. 候选：Netflix→日本、ChatGPT→美国，服务范围、规则数量、Diff 与验证限制。
5. 确认到草稿、撤销、放弃、被后续预览取代；旧条目不允许再次确认。
6. 错误提示持续可见；Toast 自动消失不得移除问题说明。
7. 浅/深色、长文件名/出口、长 Diff、窄窗口、用户上翻历史及回到底部。

不做：真实配置上传、订阅下载、真实 AI、VPN/Controller、任意 shell、Git 分支、伪造已保存会话、网页原型直接包装成原生应用。

## 原生组件责任与最小落地顺序

1. `EditorView`：主区域与可切换审阅布局；复用现有 sidebar、header、composer 和 import sheet。
2. `ConversationTurnView`：紧凑文件条目与摘要；复用 turn 的披露/确认/撤销状态。
3. 将现有 Diff 视图提取为共享 View，让时间线和审阅区使用同一份 `diffLines`，不重复解析或生成规则。
4. 用现有 `ConversationScrollState` 保留阅读历史行为；打开审阅不能自动恢复跟随。
5. 在 UI 侧持有审阅候选 ID；从 model 查找 turn，候选已失效时只能阅读、不允许确认。不在 UI 缓存第二份草稿或修改业务状态机。

本次尚未改动任何上述源文件。原生落地需在可点击原型审阅后执行。

## 已执行检查与剩余差异

- clone-website 安装成功，SKILL.md 与 inspection-guide.md 存在并已读取。
- 用户同意后，Impeccable 更新报告完成；安装文件版本为 4.5.2。本轮研究按先前加载的规则完成，新版在下一轮使用。
- 参考检出工作区干净，HEAD 与固定提交一致；未执行参考仓库脚本或安装其依赖。
- 计划、参考路径与许可均已记录。因为尚未实现原型／程序，没有运行声称针对新 UI 的测试或构建。
- 真实 OpenCode v2 画面、字体度量、交互时序与截图对比待补；源码声明的值不等同实测。
- 现有 `native/macos/.impeccable/design.json` 在上下文检查中被标记为落后于 DESIGN.md；不作为此次源码研究的视觉依据，不擅自刷新。

下一步：确认上述宽窗口可收起审阅区的构图，制作 `prototype/opencode-review/`。在确认前按照 impeccable 的 shape 流程停在设计简报，不替换当前程序。
