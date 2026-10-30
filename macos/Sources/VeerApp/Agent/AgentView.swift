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
                .frame(width: Metrics.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                if !proxy.suggestions.isEmpty {
                    SuggestionCards(limit: 1).padding(Spacing.lg)
                    Divider()
                }
                AgentConversation()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { agent.undo() } label: { Label(String(localized: "撤销修改"), systemImage: "arrow.uturn.backward") }
                    .help(String(localized: "撤销这个对话里最近应用的修改"))
                    .disabled(!agent.canUndo)
                // ⌘N is the File menu's, on every page.
                Button { agent.newThread() } label: { Label(String(localized: "新对话"), systemImage: "square.and.pencil") }
                    .help(String(localized: "新对话（⌘N）"))
                    .disabled(proxy.activeProfile == nil)
            }
        }
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
        if proxy.activeProfile == nil {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "导入一个配置后，就可以用一句话调整它的分流。"))
        } else if !agent.aiConfigured && agent.current == nil {
            if compact {
                // The setup form needs the page's width.
                StateView(symbol: "sparkles", title: String(localized: "先选择一个 AI 服务"),
                          message: String(localized: "Veer 使用你自己的 API Key，或者本机的 Ollama。"),
                          actionTitle: String(localized: "设置 AI 服务…")) { proxy.page = .agent }
            } else {
                AISetupView()
            }
        } else {
            VStack(spacing: 0) {
                if agent.profileIsInactive, let name = agent.profile?.name {
                    StatusBadge(kind: .info, text: String(localized: "这个对话属于配置“\(name)”，它现在没有在运行。"))
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.subtleFill)
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
    /// The Agent's sheets and confirmations, once per window: the page and the panel both raise them.
    func agentPresentations(_ agent: AgentStore) -> some View {
        modifier(AgentPresentations(agent: agent))
    }
}

private struct AgentPresentations: ViewModifier {
    @Bindable var agent: AgentStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $agent.editingGroup) { GroupEditorSheet(target: $0) }
            .sheet(item: Binding(get: { agent.payloadTurn }, set: { _ in agent.payloadTurnID = nil })) { PayloadSheet(turn: $0) }
            .alert(String(localized: "删除对话？"), isPresented: Binding(get: { agent.pendingDeletion != nil }, set: { if !$0 { agent.pendingDeletion = nil } })) {
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

    var body: some View {
        List(selection: Binding(get: { agent.selectedID }, set: { if let id = $0 { agent.select(id) } })) {
            ForEach(agent.sessions) { session in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(session.title).lineLimit(1)
                    Text(subtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, Spacing.xxs)
                .tag(session.id)
                .contextMenu {
                    Button(String(localized: "删除对话…"), role: .destructive) { agent.pendingDeletion = session }
                }
            }
        }
        .overlay {
            if agent.sessions.isEmpty {
                Text(String(localized: "还没有对话")).font(.callout).foregroundStyle(.secondary)
            }
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
