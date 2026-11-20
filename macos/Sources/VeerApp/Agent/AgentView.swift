import SwiftUI
import VeerCore
import VeerProxy

/// The Agent page: conversations on the left, the selected one with its composer on the right.
struct AgentView: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy

    var body: some View {
        HStack(spacing: 0) {
            ThreadList()
                // On the page's background: the list's own begins 14 pt below the window's top,
                // a step behind the title's glass in dark mode.
                .scrollContentBackground(.hidden)
                .frame(width: Metrics.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                if inWindow {
                    // One conversation on screen at a time: its window has it, with the one composer.
                    // The list here still chooses what the window shows.
                    StateView(symbol: "macwindow.on.rectangle", title: String(localized: "对话在独立窗口中"),
                              message: String(localized: "在列表中选择对话，它会显示在 Agent 窗口里。"),
                              actionTitle: String(localized: "显示 Agent 窗口")) { proxy.openAgentWindow() }
                } else {
                    if !proxy.suggestions.isEmpty {
                        SuggestionCards(limit: 1).padding(Spacing.lg)
                        Divider()
                    }
                    AgentConversation()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(.agent) {
            Button { agent.undo() } label: { Label(String(localized: "撤销修改"), systemImage: "arrow.uturn.backward") }
                .help(String(localized: "撤销这个对话里最近应用的修改"))
                .disabled(!agent.canUndo)
            // ⌘N is the File menu's, on every page.
            Button { agent.newThread() } label: { Label(String(localized: "新对话"), systemImage: "square.and.pencil") }
                .help(String(localized: "新对话（⌘N）"))
                .disabled(proxy.activeProfile == nil)
            Button { agent.pendingDeletion = agent.current } label: { Label(String(localized: "删除对话…"), systemImage: "trash") }
                .help(String(localized: "删除对话…"))
                .disabled(agent.current == nil)
        }
    }

    /// The window shows the conversation, unless the AI service is still to be chosen: that form
    /// needs the page's width, and the window sends people here for it.
    private var inWindow: Bool {
        proxy.agentPresentation == .detached && (agent.aiConfigured || agent.current != nil)
    }
}

/// The Agent in the side panel: narrower margins, and setup sent to the Agent page.
private struct AgentCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Not @Entry: Command Line Tools ship without the SwiftUI macro plugin.
    var agentCompact: Bool {
        get { self[AgentCompactKey.self] }
        set { self[AgentCompactKey.self] = newValue }
    }
}

/// The selected conversation with its composer, or what comes before one: no profile, no AI
/// service, an empty conversation. The Agent page's right column and the side panel.
struct AgentConversation: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy
    @Environment(\.agentCompact) private var compact

    var body: some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = agent.toast {
                    ToastView(toast: toast) { agent.undo() }
                        .padding(.bottom, 120)
                        .padding(.horizontal, compact ? Spacing.md : 0)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.standard, value: agent.toast)
    }

    @ViewBuilder private var content: some View {
        // An archived conversation stays readable on the Agent page after the last profile is deleted;
        // the panel, which has no list to pick it from, asks for a profile instead.
        if proxy.activeProfile == nil && (compact || !agent.isArchived) {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "导入一个配置后，就可以用一句话调整它的分流。"))
        } else if !agent.aiConfigured && agent.current == nil {
            if compact {
                // The setup form needs the page's width.
                StateView(symbol: "sparkles", title: String(localized: "先选择一个 AI 服务"),
                          message: String(localized: "Veer 使用你自己的 API Key，或者本机的 Ollama。"),
                          actionTitle: String(localized: "设置 AI 服务…")) { proxy.showPage(.agent) }
            } else {
                AISetupView()
            }
        } else {
            VStack(spacing: 0) {
                if agent.profileIsInactive, let name = agent.profile?.name {
                    // An inline banner with its own shape and margins. A bare color behind it runs on
                    // into the safe area above, under the toolbar's row or the panel's header.
                    StatusBadge(kind: .info, text: String(localized: "这个对话属于配置“\(name)”，它现在没有在运行。"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                        .padding(.horizontal, compact ? Spacing.md : Spacing.xl)
                        .padding(.top, Spacing.sm)
                }
                if agent.current == nil {
                    AgentWelcome()
                    ComposerView()
                        .padding(.horizontal, compact ? Spacing.md : Spacing.xl)
                        .padding(.bottom, compact ? Spacing.md : Spacing.lg)
                        .frame(maxWidth: Metrics.readingWidth)
                        .frame(maxWidth: .infinity)
                } else {
                    // Brings its own composer.
                    ConversationView().id(agent.selectedID)
                }
            }
        }
    }
}

extension View {
    /// The Agent's sheets and confirmations, once per window and each in one window only: the page and
    /// the panel both raise them. Turns raise the conversation's, the Agent page's list the deletion.
    func agentPresentations(_ agent: AgentStore, scope: AgentPresentationScope = .all) -> some View {
        modifier(AgentPresentations(agent: agent, scope: scope))
    }
}

/// Which of the Agent's sheets a window raises. While the Agent has a window of its own, its turns
/// are there, and the main window keeps only the deletion its list asks for.
struct AgentPresentationScope: OptionSet {
    let rawValue: Int
    static let conversation = AgentPresentationScope(rawValue: 1)
    static let deletion = AgentPresentationScope(rawValue: 2)
    static let all: AgentPresentationScope = [.conversation, .deletion]
}

private struct AgentPresentations: ViewModifier {
    @Bindable var agent: AgentStore
    let scope: AgentPresentationScope

    func body(content: Content) -> some View {
        let conversation = scope.contains(.conversation)
        content
            .sheet(item: conversation ? $agent.editingGroup : .constant(nil)) { GroupEditorSheet(target: $0) }
            .sheet(item: Binding(get: { conversation ? agent.payloadTurn : nil }, set: { _ in agent.payloadTurnID = nil })) { PayloadSheet(turn: $0) }
            .alert(String(localized: "删除对话？"),
                   isPresented: Binding(get: { scope.contains(.deletion) && agent.pendingDeletion != nil }, set: { if !$0 { agent.pendingDeletion = nil } })) {
                Button(String(localized: "删除"), role: .destructive) { if let session = agent.pendingDeletion { agent.delete(session) } }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "对话记录会从本机删除；已经应用的修改仍在“我的分流”里。"))
            }
    }
}

extension AgentStore {
    var payloadTurn: Turn? { current?.turns.first { $0.id == payloadTurnID } }
}

/// Conversations, newest first.
private struct ThreadList: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy
    /// Closed each time the list appears, unless the conversation shown is one of them.
    @State private var showsArchived = false

    var body: some View {
        let archived = agent.sessions.filter(agent.isArchived)
        List(selection: Binding(get: { agent.selectedID }, set: { if let id = $0 { agent.select(id) } })) {
            ForEach(agent.sessions.filter { !agent.isArchived($0) }, content: row)
            if !archived.isEmpty {
                // Their profile was deleted: kept to read, folded away below the ones that can still be
                // continued. A disclosure group rather than a collapsible section, whose chevron shows
                // only on hover.
                DisclosureGroup(isExpanded: $showsArchived) {
                    ForEach(archived, content: row)
                } label: {
                    Text(String(localized: "已归档（\(archived.count)）")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { showsArchived = agent.current.map(agent.isArchived) ?? false }
        .onDeleteCommand(perform: agent.current == nil ? nil : { agent.pendingDeletion = agent.current })
        .overlay {
            if agent.sessions.isEmpty {
                Text(String(localized: "还没有对话")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(session.title).lineLimit(1)
            // Not secondary when selected: it fades too far on the selection's color.
            Text(subtitle(session)).font(.caption)
                .foregroundStyle(agent.selectedID == session.id ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionHighlight(agent.selectedID == session.id)
        .tag(session.id)
        .contextMenu {
            Button(String(localized: "删除对话…"), role: .destructive) { agent.pendingDeletion = session }
        }
    }

    private func subtitle(_ session: Session) -> String {
        let profile = session.profileID.flatMap { id in proxy.profiles.first { $0.id == id }?.name } ?? String(localized: "已删除的配置")
        return "\(Format.relative(session.updatedAt)) · \(profile)"
    }
}

/// An empty conversation: what to say, with examples to try.
private struct AgentWelcome: View {
    @Environment(AgentStore.self) private var agent

    static let examples = [String(localized: "Netflix 走日本"), String(localized: "ChatGPT 走美国"),
                           String(localized: "为什么 github.com 走了代理？"), String(localized: "example.com 直连")]

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Color.veerAccent)
            Text(String(localized: "想让流量怎么走？")).font(.title2.weight(.semibold))
            Text(String(localized: "用一句话说出来。Veer 会先给出修改让你确认，应用后运行中的内核立即生效。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            FlowLayout(spacing: Spacing.sm) {
                ForEach(Self.examples, id: \.self) { example in
                    Chip(text: example, symbol: "arrow.up.right") { agent.draftInstruction(example) }
                }
            }
        }
        .frame(maxWidth: 480)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// First visit without an AI service: choose one and save its key, here rather than in settings.
private struct AISetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "先选择一个 AI 服务")).font(.title2.weight(.semibold))
                    Text(String(localized: "Veer 使用你自己的 API Key，或者本机的 Ollama。Key 只保存在这台 Mac 上；发给 AI 的配置会先匿名化，服务器地址、密码和订阅链接不会发送。"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                AISettingsPane()
                    .frame(minHeight: 420)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: Metrics.readingWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Turn {
    var isRuntime: Bool { if case .runtime = outcome { true } else { false } }
}
