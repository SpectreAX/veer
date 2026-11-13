# OpenCode 参考原型 → SwiftUI 落地

用户已确认原型并要求开始落地。原型来源与交互见 OPENCODE_UI_ADOPTION_PLAN_2026-10-14.md / OPENCODE_PROTOTYPE_VERIFICATION_2026-10-14.md。

## 本轮实施与验收顺序

1. 审阅状态：独立 selected turn ID / presented 标志，导入时重置；每个 turn 保存服务范围展开状态。测试历史只读、当前候选确认与栈顶撤销。
2. 原生 View：紧凑消息/文件变更 → 点击旁置审阅；抽出共享 Diff 与审阅 View，不拷贝业务或第二份草稿。
3. 尺寸适配：默认窗口并排，窄窗口审阅覆盖对话；对话保持挂载及原尺寸，关闭后保留历史位置。使用现有系统字体、语义色、SF Symbols 和 Liquid Glass。
4. 验证：Node 规则服务整合测试驱动 Swift Tests、Release 构建/签名、独立原生应用副本，用无节点/无密钥夹具验证导入、预览、确认、撤销、旧结果只读、取消/失败、浅深色、长文本与窄窗口。
5. 独立终审与更新原生设计记录；保留用户未保存的旧窗口，不自动替换其会话。

FIRST VIEWPORT：原生侧栏＋单行文件标题/操作；中央对话含用户指令、真实处理记录、明确出口和紧凑文件条目；右侧可关闭审阅，出口、范围、单行 Diff、验证限制、确认到草稿；底部原生 composer。

签名交互：文件条目选择同一轮 turn，审阅只引用已有结果；旧结果可看不可重确认。宽度由当前窗口决定而非设备型号。原生版不引入网页演示计时、CSS 色值、虚构验证或模型思维链。

边界：编辑协议、订阅/密钥处理、AI 匿名上下文和代理内核不改。本机编辑服务仍需运行。本轮不测试真实订阅或真实 AI，不读取钥匙串值。

现有 DESIGN/索引的历史漂移只在本次已授权原生界面变化范围更新，不重写 Android 或 Web 原型。

## 本轮执行与验证

- 已新增 ConversationReviewState、按 turn 的范围披露状态和当前 turn 操作守卫；旧记录仍可阅读，不能确认或撤销不属于栈顶的操作。
- ConversationTurnView 改为摘要/紧凑文件条目；ConversationReviewView 与 ConversationDiffView 只读取同一 model/turn。
- Detail 宽度达到 1000pt 时并排，审阅宽度 44% 并限制 420–540pt；窄窗口覆盖对话，保留原 ScrollView 的挂载、布局和内容位置，隐藏命中/辅助技术访问。
- 29 项 Swift Tests 通过（VeerMac 15 / VeerEditor 14），使用本机临时服务验证真实导入/生成/确认/撤销/失效流程；Release 构建与 ad-hoc 签名验证通过。仍有 CommandLineTools 旧目录的非阻断链接警告。
- 独立副本 `/tmp/Veer Native OpenCode Review 20261014.app`：无密钥/无节点夹具导入；真实本地解析多服务 10 条规则，确认；第二轮 Netflix→美国 6 条变更，再确认；第一轮“撤销此修改”禁用。
- 范围展开→确认→关闭/重开后 on；浅深色、长出口、单行 Diff 完成原生检查。
- 系统 Move & Resize 将验收副本缩到最小宽度 1080pt、内容最小高度 700pt（含系统标题区截图为 2160×1476px）。紧凑审阅打开时对话从辅助技术树隐藏；关闭后历史滚动值 0.4880382775119617→0.4880382775119617。
- 原生完整副本导出到 `/tmp/veer-native-opencode-edited-20261014.yaml`，解析确认含当前 Netflix/ChatGPT→美国 10 条服务规则与 MATCH；原 YAML 的非 rules 前缀逐字一致，不覆盖夹具。
- 原生画面位于 `native/macos/artifacts/opencode-2026-10-14/`：首页、浅深色并排、紧凑/最小审阅、历史前后、旧结果只读。

验收开始时本机编辑服务未运行，已启动 `prototype/ai-editor` 的 npm start（127.0.0.1:4317）。未调用真实 AI、未访问真实订阅、未读取钥匙串值。取消/失败等流程有整合测试覆盖；真实长耗时 AI、VoiceOver、旧 OS、减少透明度和公开签名/公证本轮未实测。

独立原生终审结论：本轮限定范围内的原生 UI 为 **ship**，没有新增 UI 修正项。终审核对了 8 张原生截图、选中轮次与披露状态、历史只读/栈顶撤销守卫和窄窗口保留对话的实现；不将这一结论扩展到公开发行、真实 AI 或未实测的辅助功能。没有浏览器/CSS detector，因为其不能审查 SwiftUI。

设计交付已同步 `native/macos/DESIGN.md`、`PRODUCT.md`、`.impeccable/design.json` 与 README；旧轮次证据保留为历史，当前布局与验收边界已更新。设计 JSON、文档结构与 8 张截图路径检查通过。采用 write-swift 的值类型审阅状态，按 impeccable 的原生适配与终审流程复用现有系统控件、语义色和操作层玻璃，没有新增一套视觉语言或草稿业务副本。

新版应用：`native/macos/dist/Veer AI Editor.app`。用户原窗口未强制关闭；先导出需要保留的草稿，再退出旧版本并打开新版。独立验收副本不含用户真实配置。
