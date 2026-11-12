import SwiftUI
import VeerCore

struct AgentComposerView: View {
    @Environment(AgentStore.self) private var agent
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focused: Bool
    @State private var automatic = true
    @State private var sendFeedback = 0

    private var fixture: Bool { agent.settings.model == FixtureAI.model }

    private var canSend: Bool {
        !agent.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agent.isArchived
    }

    var body: some View {
        @Bindable var agent = agent
        VStack(alignment: .leading, spacing: Spacing.s) {
            // SwiftUI truncates a TextField's own placeholder to one line; draw it ourselves so
            // the hint wraps (up to two lines) instead of ending in an ellipsis.
            ZStack(alignment: .topLeading) {
                if agent.composerText.isEmpty {
                    Text(placeholder)
                        .font(.body).foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $agent.composerText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .focused($focused)
                    .accessibilityLabel(placeholder)
                    .accessibilityIdentifier("agent-composer")
            }
            if typeSize.isAccessibilitySize {
                compactControls
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        parseMenu
                        modelMenu
                        if !fixture { webButton }
                        Spacer(minLength: 0)
                        sendButton
                    }
                    compactControls
                }
            }
        }
        .padding(Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.hero))
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedback)
        .onChange(of: agent.composerFocusToken) { focused = true }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { parseMenu; Spacer(); sendButton }
            AgentFlowLayout(spacing: Spacing.s, leading: true) {
                modelMenu
                if !fixture { webButton }
            }
        }
    }

    private var parseMenu: some View {
        Menu {
            Button("自动") { automatic = true; agent.useAI = true }
            Button("AI") { automatic = false; agent.useAI = true }
            Button("本地解析") { automatic = false; agent.useAI = false }
        } label: {
            Label(parseLabel, systemImage: "a.circle")
                .font(.caption).padding(.horizontal, 9).frame(minHeight: 32)
                .background(Color.quietFill, in: .capsule)
                .frame(minHeight: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(agent.useAI ? String(localized: "AI") : String(localized: "本地解析。轻点选择 AI 或本地解析"))
        .accessibilityIdentifier("agent-parse-mode")
    }

    private var modelMenu: some View {
        Menu {
            if !agent.aiConfigured {
                Button("设置 AI 服务…") { model.showingSettings = true }
            }
            Picker("模型", selection: Binding(get: { agent.settings.model }, set: { agent.settings.model = $0 })) {
                ForEach(models, id: \.self) { name in Text(name).tag(name) }
            }
            .disabled(fixture)
            Picker("深度思考", selection: Binding(get: { agent.settings.thinkingLevel }, set: { agent.settings.thinkingLevel = $0 })) {
                ForEach(agent.settings.provider.thinkingStyle(for: agent.settings.model).levels) { level in
                    Text(level.title).tag(level)
                }
            }
            .disabled(fixture)
            Button("设置 AI 服务…") { model.showingSettings = true }
            Button("改用本地解析") { agent.useAI = false }
        } label: {
            Label(providerTitle, systemImage: "sparkles")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 9).frame(minHeight: 32)
                .background(Color.quietFill, in: .capsule)
                .frame(minHeight: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(fixture ? FixtureAI.label : String(format: String(localized: "AI · %@。轻点选择模型、思考强度或改用本地解析"), agent.settings.model))
        .accessibilityIdentifier("agent-model")
    }

    private var webButton: some View {
        Button { agent.searchSettings.enabled.toggle() } label: {
            Label("联网搜索", systemImage: "globe")
                .font(.caption)
                .padding(.horizontal, 9).frame(minHeight: 32)
                .foregroundStyle(agent.searchSettings.enabled ? Color.veerAccent : Color.secondary)
                .background(agent.searchSettings.enabled ? Color.veerAccent.opacity(0.16) : Color.quietFill, in: .capsule)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!agent.useAI)
        .accessibilityLabel("AI 可以联网搜索规则集和官方域名（轻点关闭）")
        .accessibilityValue(agent.searchSettings.enabled ? String(localized: "开启") : String(localized: "关闭"))
        .accessibilityIdentifier("agent-web")
    }

    private var sendButton: some View {
        Button {
            sendFeedback += 1
            if agent.isRunning { agent.cancel() } else {
                focused = false
                // Parsing mode is separate from execution permission: always review proposals
                // before writing a routing edit in this prototype.
                agent.send(executionMode: .manual)
            }
        } label: {
            Image(systemName: agent.isRunning ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(canSend || agent.isRunning ? Color.onAccent : Color.secondary)
                .frame(width: 34, height: 34)
                .background(canSend || agent.isRunning ? Color.accentFill : Color.quietFill, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !agent.isRunning)
        .accessibilityLabel(agent.isRunning ? String(localized: "停止生成") : String(localized: "发送"))
        .accessibilityIdentifier("agent-send")
    }

    private var placeholder: String { String(localized: "描述分流，例如“Netflix 走日本，ChatGPT 走美国”") }

    private var parseLabel: String {
        if !agent.useAI { return String(localized: "本地解析") }
        return automatic ? String(localized: "自动") : String(localized: "AI")
    }
    private var providerTitle: String {
        // Short pill text keeps the controls on one row; VoiceOver still reads the full label.
        if fixture { return String(localized: "示例") }
        return agent.settings.provider == .ollama ? String(localized: "Ollama（局域网）") : agent.settings.provider.title
    }
    private var models: [String] {
        Array(Set([agent.settings.model] + agent.settings.provider.catalog.map(\.model) + agent.settings.fetchedModels)).sorted()
    }
}
