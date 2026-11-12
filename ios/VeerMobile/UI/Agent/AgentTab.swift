import SwiftUI
import VeerCore

struct AgentTab: View {
    @Environment(AppModel.self) private var model
    @Environment(ProxyStore.self) private var proxy
    @Environment(AgentStore.self) private var agent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 46
    @State private var showingConversations = false

    private var empty: Bool { agent.current?.turns.isEmpty ?? true }
    private var needsSetup: Bool { empty && agent.useAI && !agent.aiConfigured }
    private var canCompose: Bool { proxy.activeProfile != nil && !needsSetup && !agent.isArchived }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        if proxy.activeProfile == nil && empty {
                            missingProfile
                        } else if needsSetup {
                            setup
                        } else if empty {
                            AgentWelcomeView()
                        } else {
                            if agent.profileIsInactive, let name = agent.profile?.name {
                                StatusBadge(kind: .info, text: String(localized: "这个对话属于配置“\(name)”，它现在没有在运行。"))
                            }
                            if agent.isArchived {
                                StatusBadge(kind: .neutral, text: String(localized: "已归档"))
                            }
                            // Undo/re-apply notes repeat what the proposal card already says.
                            ForEach(visibleTurns) { turn in
                                AgentTurnView(turn: turn).id(turn.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("agent-bottom")
                    }
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: agent.conversationToken) {
                    withAnimation(reduceMotion ? nil : Motion.standard) { reader.scrollTo("agent-bottom", anchor: .bottom) }
                }
            }
            .background(Color.groupedBackground)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: Spacing.m) {
                    if let toast = agent.toast { toastView(toast) }
                    if canCompose { AgentComposerView() }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)
            }
            .sheet(isPresented: $showingConversations) { AgentConversationsSheet() }
            .sheet(isPresented: Binding(get: { agent.payloadTurnID != nil }, set: { if !$0 { agent.payloadTurnID = nil } })) {
                AgentPayloadSheet()
            }
            .alert("删除对话？", isPresented: Binding(get: { agent.pendingDeletion != nil }, set: { if !$0 { agent.pendingDeletion = nil } })) {
                Button("删除", role: .destructive) {
                    if let session = agent.pendingDeletion { agent.delete(session) }
                    agent.pendingDeletion = nil
                }
                Button("取消", role: .cancel) { agent.pendingDeletion = nil }
            } message: {
                Text("对话记录会从本机删除；已经应用的修改仍在“我的分流”里。")
            }
            .sensoryFeedback(.success, trigger: agent.toast?.id) { _, _ in agent.toast?.undoable == true }
            .onChange(of: agent.toast?.id) {
                if let toast = agent.toast { AccessibilityNotification.Announcement(toast.message).post() }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: agent.toast?.id)
            .task {
                guard !opened else { return }
                opened = true
                openActiveProfile()
            }
            .onChange(of: proxy.activeProfileID) {
                // Import may supply the first profile while this tab remains mounted. Never
                // replace a selected history conversation just because SwiftUI renders again.
                if agent.current == nil { openActiveProfile() }
            }
        }
    }

    private var visibleTurns: [Turn] {
        (agent.current?.turns ?? []).filter { turn in
            if case .note = turn.outcome { return false }
            return true
        }
    }

    // Toolbar glyphs stay .primary; green is reserved for actions with a result.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingConversations = true } label: { Image(systemName: "list.bullet") }
                .tint(.primary)
                .accessibilityLabel("对话")
                .accessibilityIdentifier("agent-conversations")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { agent.newThread() } label: { Image(systemName: "square.and.pencil") }
                .tint(.primary)
                .disabled(proxy.activeProfile == nil)
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("agent-new")
            Menu {
                Button("撤销修改", systemImage: "arrow.uturn.backward") { agent.undo() }
                    .disabled(!agent.canUndo)
                Button("删除对话…", systemImage: "trash", role: .destructive) { agent.pendingDeletion = agent.current }
                    .disabled(agent.current == nil)
            } label: { Image(systemName: "ellipsis") }
            .tint(.primary)
            .accessibilityLabel("更多")
            .accessibilityIdentifier("agent-more")
        }
    }

    private var missingProfile: some View {
        ContentUnavailableView {
            Label("还没有配置", systemImage: "tray")
        } description: {
            Text("导入一个配置后，就可以用一句话调整它的分流。")
        } actions: {
            Button("导入配置…") { model.showingImport = true }
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("agent-import")
        }
        .padding(.top, Spacing.xxxl)
    }

    private var setup: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "sparkles").font(.system(size: symbolSize)).foregroundStyle(Color.veerAccent)
                .accessibilityHidden(true)
            Text("先选择一个 AI 服务").font(.title2.bold())
            Text("Veer 使用你自己的 API Key。Key 只保存在这台 iPhone 上；发给 AI 的配置会先匿名化，服务器地址、密码和订阅链接不会发送。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            // Text-width buttons, like the Overview welcome state (design review 2, item 2).
            Button("设置 AI 服务…") { model.showingSettings = true }
                .buttonStyle(.primaryCapsule).fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("agent-setup-ai")
            Button("改用本地解析") { agent.useAI = false }
                .buttonStyle(.secondaryCapsule).fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("agent-use-local")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
    }

    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: toast.undoable ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(Color.veerAccent)
            Text(toast.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            if toast.undoable {
                Button("撤销") { agent.undo() }.font(.footnote.bold()).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("agent-toast-undo")
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-toast")
    }

    private func openActiveProfile() {
        guard proxy.activeProfile != nil else { return }
        // Opening the tab is not a request to type: keep the keyboard down (newThread and open
        // ask for focus, which suits the Mac window and the New Conversation button).
        let focusToken = agent.composerFocusToken
        if agent.current == nil || agent.current?.profileID != proxy.activeProfileID { agent.newThread() }
        agent.open()
        agent.composerFocusToken = focusToken
    }
}

struct AgentWelcomeView: View {
    @Environment(AgentStore.self) private var agent
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 46
    private let suggestions = [String(localized: "Netflix 走日本"), String(localized: "ChatGPT 走美国"),
                               String(localized: "为什么 github.com 走了代理？"), String(localized: "example.com 直连")]

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "sparkles").font(.system(size: symbolSize)).foregroundStyle(Color.veerAccent)
                .accessibilityHidden(true)
            Text("想让流量怎么走？").font(.title2.bold())
            Text("用一句话说出来。Veer 会先给出修改让你确认，应用后运行中的内核立即生效。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            AgentFlowLayout(spacing: Spacing.s) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    Button { agent.composerText = suggestion; agent.composerFocusToken += 1 } label: {
                        Label {
                            Text(suggestion).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "arrow.up.right").foregroundStyle(Color.veerAccent)
                        }
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .background(Color.cardBackground, in: .capsule)
                            .overlay(Capsule().strokeBorder(Color.veerAccent.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-suggestion-\(index)")
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
    }
}

/// Intrinsic-width chips wrap instead of truncating at accessibility sizes.
struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Rows start at the leading edge instead of being centred (composer controls).
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: rows(subviews, width: width).reduce(0) { $0 + $1.height + spacing } - (subviews.isEmpty ? 0 : spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX + (leading ? 0 : max(0, (bounds.width - row.width) / 2))
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !row.indices.isEmpty && row.width + spacing + size.width > width { result.append(row); row = Row() }
            if !row.indices.isEmpty { row.width += spacing }
            row.indices.append(index); row.width += size.width; row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }
}
