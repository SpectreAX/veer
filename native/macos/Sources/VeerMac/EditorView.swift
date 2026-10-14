import SwiftUI
import VeerEditor

enum EditorLayout {
    static let small: CGFloat = 8
    static let section: CGFloat = 16
    static let padding: CGFloat = 24
    static let paneMinimum: CGFloat = 340
    static let editorHeight: CGFloat = 240
    static let promptHeight: CGFloat = 120
}

let declaredRegions = [("UNKNOWN", "未指定地区"), ("JP", "日本"), ("US", "美国"), ("HK", "香港"), ("SG", "新加坡"), ("TW", "台湾"), ("KR", "韩国"), ("GB", "英国"), ("DE", "德国"), ("AUTO", "自动")]

struct EditorView: View {
    // Approved OpenCode-reference composition: import canvas, conversation and on-demand review.
    // The 144pt glass plus is the only primary empty-state action.
    // After local import, conversation reviews rule-only changes before confirmation.
    // No original config, node credentials or provider URLs enter the AI context.
    @Bindable var model: EditorModel
    @FocusState private var editingRules: Bool
    @AppStorage("editor.appearance") private var appearance = EditorAppearance.system
    @AppStorage("editor.opaqueControls") private var opaqueControls = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: WorkbenchStyle.sidebar, max: 210)
        } detail: {
          VStack(spacing: 0) {
            header
            if let issue = model.issue {
                HStack(alignment: .top, spacing: EditorLayout.small) {
                    Image(systemName: "exclamationmark.triangle")
                    ScrollView {
                        Text(issue).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: WorkbenchStyle.composerHeight)
                        .accessibilityLabel("错误详情，可滚动查看完整内容")
                    Button("关闭") { model.issue = nil }.buttonStyle(.plain)
                }
                .font(.callout).foregroundStyle(.red)
                .padding(.horizontal, WorkbenchStyle.inset).padding(.bottom, EditorLayout.section)
            }
            page
          }
          .background(Color(nsColor: .windowBackgroundColor))
          .overlay(alignment: .bottom) {
              if !model.status.isEmpty && !model.busy {
                  statusBar.padding(EditorLayout.section)
                      .frame(maxWidth: WorkbenchStyle.contentWidth)
              }
          }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(appearance.scheme)
        .environment(\.veerOpaqueControls, opaqueControls)
        .frame(minWidth: 1080, minHeight: 700)
        .sheet(isPresented: $model.showingImport) { importSheet }
        .task(id: ToastTrigger(generation: model.statusGeneration, busy: model.busy, isError: model.isError)) {
            guard !model.busy, !model.status.isEmpty else { return }
            let generation = model.statusGeneration
            do {
                try await Task.sleep(for: .seconds(model.isError ? 8 : 4))
                try Task.checkCancellation()
                model.dismissStatus(generation: generation)
            } catch { /* New feedback, a running request, or window exit cancels this lifetime. */ }
        }
        .task(id: model.settings.baseUrl) { await model.restoreKeyStatus() }
        .onChange(of: editingRules) { _, focused in if !focused { model.session.endEditing() } }
        .onDisappear { model.cancel() }
        .onExitCommand {
            if model.busy { model.cancel() }
            else { model.dismissStatus(generation: model.statusGeneration) }
        }
    }

    private var utilityActions: some View {
            HStack(spacing: EditorLayout.small) {
                UtilityButton(title: "导入配置（⌘O）", symbol: "plus") { model.requestImport() }
                    .disabled(model.busy).keyboardShortcut("o", modifiers: .command)
                UtilityButton(title: "撤销草稿（⇧⌘Z）", symbol: "arrow.uturn.backward") { model.undo() }
                    .disabled(model.busy || !model.session.canUndo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                UtilityButton(title: model.hasDocument ? "导出完整配置（⌘E）" : "导出规则片段（⌘E）", symbol: "square.and.arrow.up") { model.exportRules() }
                    .disabled(model.busy)
                    .keyboardShortcut("e", modifiers: .command)
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: EditorLayout.section) {
            (Text("Veer") + Text(".").foregroundColor(.green))
                .font(.title2.weight(.semibold)).padding(.horizontal, EditorLayout.padding)
                .padding(.vertical, EditorLayout.section)
            List(selection: $model.section) {
                Section("编辑") {
                    ForEach([WorkbenchSection.editor, .rules]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                Section("配置") {
                    Label(WorkbenchSection.groups.title, systemImage: WorkbenchSection.groups.symbol).tag(WorkbenchSection.groups)
                    Label(WorkbenchSection.settings.title, systemImage: WorkbenchSection.settings.symbol).tag(WorkbenchSection.settings)
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: EditorLayout.small) {
                Text("完整配置仅在本机解析\nAI 不接收节点或密钥")
                    .font(.caption).foregroundStyle(.secondary)
                Text("仅修改规则 · 不控制代理")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(EditorLayout.section)
        }
    }

    private var header: some View {
        HStack(spacing: EditorLayout.small) {
            if (model.section ?? .editor) != .editor || model.hasDocument {
                VStack(alignment: .leading, spacing: EditorLayout.small) {
                    Text(model.section == .editor ? model.importedName : (model.section ?? .editor).title)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(model.importedName)
                    Text(model.hasDocument ? "仅编辑规则 · 未应用到代理" : "配置仅在本机处理")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: WorkbenchStyle.headerTitleWidth, alignment: .leading)
            }
            Spacer(minLength: EditorLayout.small)
            if model.hasDocument { utilityActions }
            if model.hasDocument && (model.section ?? .editor) == .editor {
                UtilityButton(title: model.review.isPresented ? "关闭修改审阅" : "打开修改审阅", symbol: "sidebar.right") { model.toggleReview() }
                    .accessibilityValue(model.review.isPresented ? "已展开" : "已收起")
            }
            Menu {
                Button("检查规则格式") { model.checkRules() }.disabled(model.busy || !model.hasDocument)
                Toggle("减少透明度", isOn: $opaqueControls)
            } label: { Image(systemName: "ellipsis").frame(width: WorkbenchStyle.utilitySize, height: WorkbenchStyle.utilitySize) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
                .fixedSize().frame(width: WorkbenchStyle.utilitySize, height: WorkbenchStyle.utilitySize)
                .modifier(OperationGlass()).accessibilityLabel("更多操作")
            UtilityButton(
                title: (appearance.scheme ?? colorScheme) == .dark ? "切换为浅色外观" : "切换为深色外观",
                symbol: (appearance.scheme ?? colorScheme) == .dark ? "sun.max" : "moon"
            ) { appearance = appearance.toggled(resolvedScheme: colorScheme) }
                .accessibilityValue((appearance.scheme ?? colorScheme) == .dark ? "深色" : "浅色")
        }.padding(.horizontal, WorkbenchStyle.inset).padding(.vertical, EditorLayout.small)
    }

    @ViewBuilder private var page: some View {
        switch model.section ?? .editor {
        case .editor:
            conversationPage
        case .rules:
            singlePage { WorkbenchPanel { rulesSection } }
        case .groups:
            singlePage { WorkbenchPanel { groupsSection } }
        case .settings:
            singlePage { WorkbenchPanel { aiSettingsFields } }
        }
    }

    private var conversationPage: some View {
        GeometryReader { geometry in
            let compactReview = model.hasDocument && model.review.isPresented && geometry.size.width < WorkbenchStyle.reviewSplitThreshold
            ZStack {
                HStack(alignment: .top, spacing: EditorLayout.section) {
                    // Keep the conversation mounted at its full compact width beneath review.
                    // A removed/zero-width ScrollView loses layout and reading position.
                    conversationColumn
                        .opacity(compactReview ? 0 : 1)
                        .allowsHitTesting(!compactReview)
                        .accessibilityHidden(compactReview)
                    if model.hasDocument && model.review.isPresented && !compactReview {
                        ConversationReviewView(model: model).frame(width: WorkbenchStyle.reviewWidth(in: geometry.size.width))
                    }
                }
                if compactReview { ConversationReviewView(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(.horizontal, EditorLayout.section).padding(.bottom, EditorLayout.section)
    }

    private var conversationColumn: some View {
        VStack(spacing: EditorLayout.padding) {
            if !model.hasDocument {
                Spacer()
                ImportGlassButton { model.requestImport() }.disabled(model.busy)
                Text("从一份配置开始").font(.title2).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EditorLayout.padding) {
                        if model.conversation.isEmpty && model.session.preview == nil {
                            Text("想如何调整分流？").font(.title)
                            Text("例如：Netflix 走日本，ChatGPT 走美国。\n出口地区由名称推断，可在策略组页面检查；没有对应出口时不会猜测。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.conversation) { turn in
                            ConversationTurnView(model: model, turn: turn).id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(EditorLayout.padding)
                }.modifier(ConversationScrollTracking(state: $model.conversationScroll))
                    .frame(maxWidth: WorkbenchStyle.contentWidth)
                    .onChange(of: model.conversation.count) { _, _ in
                        if model.conversationScroll.following { reader.scrollTo("latest", anchor: .bottom) }
                    }
                    .onChange(of: model.conversation.last?.state) { _, state in
                        if model.conversationScroll.following && (state == .pending || state == .failed || state == .cancelled) { reader.scrollTo("latest", anchor: .bottom) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !model.conversation.isEmpty && !model.conversationScroll.atBottom {
                            Button {
                                model.conversationScroll.resume()
                                reader.scrollTo("latest", anchor: .bottom)
                            } label: {
                                Label("回到最新", systemImage: "arrow.down").font(.caption)
                                    .padding(EditorLayout.small).modifier(OperationGlass())
                            }.buttonStyle(.plain).padding(EditorLayout.small)
                        }
                    }
                }
            }
            composer
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, EditorLayout.section).padding(.bottom, EditorLayout.section)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: EditorLayout.small) {
            if model.hasDocument {
                TextEditor(text: $model.prompt)
                    .scrollContentBackground(.hidden)
                    .frame(height: WorkbenchStyle.composerHeight)
                    .disabled(model.busy)
                    .accessibilityLabel("对话修改配置")
                    .overlay(alignment: .topLeading) {
                        if model.prompt.isEmpty { Text("描述你想修改的分流规则…").foregroundStyle(.secondary).padding(.leading, 4).allowsHitTesting(false) }
                    }
                HStack {
                    Picker("解析模式", selection: $model.mode) {
                        Text("本地解析").tag("local")
                        Text("AI 理解").tag("ai")
                    }.frame(maxWidth: 180).disabled(model.busy)
                    if #unavailable(macOS 15) {
                        Button(model.conversationScroll.following ? "暂停跟随" : "恢复跟随") {
                            if model.conversationScroll.following {
                                model.conversationScroll.beginInteraction()
                                model.conversationScroll.endInteraction(atBottom: false)
                            }
                            else { model.conversationScroll.resume() }
                        }.buttonStyle(.plain)
                    }
                    if model.mode == "ai" {
                        Button(model.settings.useSavedKey ? "Key 已保存" : "设置 API") { model.section = .settings }.buttonStyle(.plain)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
                    else {
                        UtilityButton(title: "发送指令，生成预览（⌘↵）", symbol: "arrow.up") { model.generate() }
                            .disabled(!model.canGenerate).keyboardShortcut(.return, modifiers: .command)
                    }
                }
                Text("AI 只接收匿名出口与指令；请勿在指令中填写密钥、订阅链接等敏感信息。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("导入配置文件或订阅链接以开始").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up").foregroundStyle(.tertiary)
                }.frame(minHeight: WorkbenchStyle.composerHeight)
            }
        }.padding(EditorLayout.section)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.radius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            .frame(maxWidth: WorkbenchStyle.contentWidth)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: EditorLayout.padding) {
            HStack {
                Text("导入配置").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { if model.busy { model.cancel() }; model.showingImport = false; model.importURL = "" }
            }
            Text("选择 Mihomo YAML 文件，或粘贴返回 YAML 的 HTTPS 订阅链接。完整配置仅在本机解析，不会发送给 AI。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { model.chooseFile() } label: { Label("从文件导入…", systemImage: "doc.badge.plus").frame(maxWidth: .infinity).padding(EditorLayout.small) }
                .modifier(GlassUtilityAction()).disabled(model.busy)
            Divider()
            Text("从 URL 导入").font(.headline)
            SecureField("HTTPS 配置或订阅链接", text: $model.importURL).textFieldStyle(.roundedBorder)
                .disabled(model.busy).onSubmit { if !model.importURL.isEmpty && !model.busy { model.importSubscription() } }
            Text("链接可能包含订阅密钥，默认隐藏；不保存链接。暂不支持 Base64 节点列表。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = model.issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("正在导入…").foregroundStyle(.secondary) }
                Spacer()
                Button("下载并导入") { model.importSubscription() }.modifier(GlassAction())
                    .disabled(model.busy || model.importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkbenchStyle.inset).frame(width: 520)
            .interactiveDismissDisabled(model.busy)
    }

    private func singlePage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: WorkbenchStyle.contentWidth).padding(.horizontal, WorkbenchStyle.inset)
                .padding(.bottom, EditorLayout.padding).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusBar: some View {
            HStack(spacing: EditorLayout.small) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: model.isError ? "exclamationmark.triangle" : "doc.text") }
                Text(model.status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if model.busy { Button("取消等待") { model.cancel() } }
                else {
                    Button { model.dismissStatus(generation: model.statusGeneration) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
            }
            .font(.callout)
            .foregroundStyle(model.isError ? Color.red : Color.primary)
            .padding(EditorLayout.section)
            .modifier(OperationGlass())
            .accessibilityElement(children: .combine)
    }


    private func regionTitle(_ region: String) -> String {
        declaredRegions.first { $0.0 == region }?.1 ?? region
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: EditorLayout.section) {
            Label(model.hasDocument ? "配置中的可用出口" : "允许使用的策略组", systemImage: "arrow.triangle.branch").font(.headline)
            Text(model.hasDocument ? "已从配置读取出口名称。地区由名称推断，可手动调整，仅供 AI 理解，并非实测。" : "名称须与代理客户端完全一致；地区由你声明，并非实测。")
                .font(.callout).foregroundStyle(.secondary)
            if !model.hasDocument {
            TextField("策略组名称", text: $model.groupName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("策略组名称")
            HStack {
                Picker("声明地区", selection: $model.groupRegion) {
                    ForEach(declaredRegions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Button("登记策略组") { model.addGroup() }
                    .disabled(model.busy || model.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            }
            if model.session.draft.groups.isEmpty {
                Text("尚未登记出口。直连 DIRECT 与屏蔽 REJECT 始终可用。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.session.draft.groups, id: \.name) { group in
                    HStack(alignment: .top, spacing: EditorLayout.small) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).textSelection(.enabled)
                            Text("声明" + (declaredRegions.first { $0.0 == group.region }?.1 ?? group.region))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.hasDocument {
                            Picker("出口地区", selection: Binding(get: { group.region }, set: { model.setRegion($0, for: group.name) })) {
                                ForEach(declaredRegions, id: \.0) { Text($0.1).tag($0.0) }
                            }.labelsHidden().frame(width: 150).disabled(model.busy)
                                .accessibilityLabel("\(group.name) 的声明地区")
                        } else {
                        Button { model.removeGroup(group.name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移除策略组，已有引用时会拒绝移除")
                            .accessibilityLabel("移除策略组 \(group.name)")
                            .disabled(model.busy)
                        }
                    }
                }
            }
            if !model.hasDocument { Button("载入演示组名（非真实配置）") { model.loadDemo() }.disabled(model.busy) }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: EditorLayout.section) {
            HStack {
                Text("规则片段").font(.headline)
                Spacer()
                Text(model.session.hasUnsavedChanges ? "未导出 · 尚未应用" : "当前规则稿")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.hasDocument ? "仅编辑 rules；节点、密钥和其他原配置字段保持不变。导出为完整 YAML。" : "只粘贴 rules YAML；不要粘贴完整配置、节点或密钥。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { model.session.draft.rules }, set: model.setRules))
                .font(.body.monospaced())
                .focused($editingRules)
                .frame(height: EditorLayout.editorHeight)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("规则 YAML")
            Divider()
            HStack {
                Text("独立片段 · 可编辑")
                Spacer()
                if let count = model.ruleCount { Text("\(count) 条规则") }
                else { Text("\(model.session.draft.rules.components(separatedBy: "\n").count) 行") }
            }.font(.caption).foregroundStyle(.secondary)
            if model.section == .rules {
                Text(model.hasDocument ? "导出完整配置副本，不覆盖原文件；请由代理客户端检查后使用。" : "导出的是规则片段，不是完整配置。请由客户端合并并检查真实组名、顺序和出口。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("草稿仅存于内存，关闭应用前请导出。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var aiSettingsFields: some View {
            VStack(alignment: .leading, spacing: EditorLayout.small) {
                Label("AI 服务", systemImage: "slider.horizontal.3").font(.headline)
                Text("API 基础地址").font(.callout)
                TextField("https://api.deepseek.com", text: Binding(get: { model.settings.baseUrl }, set: model.setBaseURL)).accessibilityLabel("API 基础地址")
                Text("模型").font(.callout)
                TextField("模型名称", text: Binding(get: { model.settings.model }, set: model.setModel)).accessibilityLabel("模型")
                Text("API Key").font(.callout)
                SecureField("可使用已保存 Key", text: Binding(get: { model.settings.apiKey }, set: model.setKey)).accessibilityLabel("API Key")
                Text(model.keyMessage).font(.caption).foregroundStyle(.secondary)
                Button("保存到钥匙串") { model.saveKey() }
                    .disabled(model.busy || model.settings.apiKey.isEmpty)
                Text("Key 按 API 地址隔离；未保存的输入仅供会话使用。暂不在原生版删除已保存 Key。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("返回 AI 工作台") { model.section = .editor }
            }.textFieldStyle(.roundedBorder).padding(.top, EditorLayout.small)
    }

}
