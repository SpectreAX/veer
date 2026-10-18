# Veer OpenCode 参考原型

用户已确认：主对话＋可收起的右侧修改审阅，窄窗口单区域；保留现有导入首页，原型审阅后再改 SwiftUI。

Mode: Operate. Build path: code-led，用户固定了参考和构图，不再进行视觉方向抽签。本地 buildless HTML/JS，仅作原生实现的交互规格，不是新的 Web 产品。

FIRST VIEWPORT：窄侧栏列当前配置和工作台；顶部文件身份与导入、导出、审阅、外观；中央用户指令、可折叠的处理记录、摘要及紧凑文件变更；右侧服务→出口与单行 Diff；底部独立输入区。未导入时只显示大玻璃加号与禁用输入提示。

Signature interaction：点击对话中的文件变更，将同一 turn 的候选送到旁置审阅；关闭后回到对话，不丢输入或披露状态。窄窗口审阅替换对话区域，返回按钮恢复原位置。

Material / type：保留 Veer 系统字体/等宽代码与绿色标识；中性实底内容，玻璃只在操作区。网页 CSS 是示意近似，不能声称真正原生 Liquid Glass。

Quality bar：明确候选和已确认到草稿的区别；当前 turn 才允许确认；取消不会产生候选；旧结果可读不可重确认；错误与 Toast 分离；Diff 不换成竖列；浅深色、390 / 1080 / 1440 宽度可读。

状态均为合成演示；没有请求、下载、文件读取、Key 输入或存储。文件/URL 入口均载入内置示例，按钮明示演示。导出只生成合成示例副本。不复制 OpenCode 商标、源代码、字体或图标；参考来源见 docs/OPENCODE_UI_REFERENCE_2026-10-14.md。

不修改 native/macos 或 prototype/ai-editor。现有 DESIGN.md 与索引不重写。本原型的样式记录单独维护。
