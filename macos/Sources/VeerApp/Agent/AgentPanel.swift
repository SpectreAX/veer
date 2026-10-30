import SwiftUI
import VeerProxy

/// The Agent beside every page but its own: the current conversation and its composer, with
/// the recent conversations in a menu and a way out to the full page.
struct AgentPanel: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy

    /// Conversations listed in the title menu; the rest are on the Agent page.
    static let recentCount = 12

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The overview lists every suggestion itself.
            if proxy.page != .overview && !proxy.suggestions.isEmpty {
                SuggestionCards(limit: 1).padding(Spacing.md)
                Divider()
            }
            AgentConversation()
        }
        .background(Color.surface)
        .environment(\.agentCompact, true)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Menu {
                ForEach(agent.sessions.prefix(Self.recentCount)) { session in
                    Toggle(session.title, isOn: Binding(get: { agent.selectedID == session.id }, set: { if $0 { agent.select(session.id) } }))
                }
                if agent.sessions.count > Self.recentCount {
                    Divider()
                    Button(String(localized: "全部对话…")) { proxy.page = .agent }
                }
            } label: {
                Label(agent.current?.title ?? String(localized: "Agent"), systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .disabled(agent.sessions.isEmpty)
            .help(String(localized: "切换对话"))
            .accessibilityLabel(String(localized: "切换对话"))
            Spacer(minLength: Spacing.sm)
            Group {
                Button { agent.undo() } label: { Label(String(localized: "撤销修改"), systemImage: "arrow.uturn.backward") }
                    .help(String(localized: "撤销这个对话里最近应用的修改"))
                    .disabled(!agent.canUndo)
                Button { agent.newThread() } label: { Label(String(localized: "新对话"), systemImage: "square.and.pencil") }
                    .help(String(localized: "新对话（⌘N）"))
                    .disabled(proxy.activeProfile == nil)
                Button { proxy.page = .agent } label: { Label(String(localized: "在 Agent 页打开"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help(String(localized: "在 Agent 页打开，查看全部对话"))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 36)
    }
}

/// One line at the top of the overview: what to change, sent straight to the panel.
struct AgentAskBar: View {
    @Environment(AgentStore.self) private var agent
    @State private var text = ""

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles").foregroundStyle(Color.veerAccent)
            TextField(String(localized: "告诉 AI 想怎么分流，例如 Netflix 走日本"), text: $text)
                .textFieldStyle(.plain)
                .onSubmit(send)
                .accessibilityLabel(String(localized: "分流指令"))
            Button(action: send) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                .help(String(localized: "发送（↩）")).accessibilityLabel(String(localized: "发送"))
                .primaryAction()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isRunning)
        }
        .panel(padding: Spacing.md)
    }

    private func send() {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !agent.isRunning else { return }
        agent.open(asking: instruction)
        // Without an AI service it waits in the panel's composer, where setup is one click away.
        if agent.aiConfigured { agent.send() }
        text = ""
    }
}
