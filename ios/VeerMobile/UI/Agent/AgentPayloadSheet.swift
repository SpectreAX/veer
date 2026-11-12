import SwiftUI
import VeerCore

struct AgentPayloadSheet: View {
    @Environment(AgentStore.self) private var agent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var comparison: AgentStore.PayloadComparisonResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let payload = agent.payloadTurn?.sentPayload {
                        modePicker
                        if agent.payloadComparing {
                            comparisonContent
                        } else {
                            AgentCodeBox(text: sentText(payload))
                                .accessibilityIdentifier("agent-payload-sent")
                        }
                        Label("未发送：真实名称、节点地址、端口、密码、协议参数、订阅与规则集地址及其他网络配置", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(.secondary)
                        Label {
                            Text("你在指令里亲自输入的内容会原样发送（出口名除外），请勿填写密钥")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("找不到发送时的配置", systemImage: "doc.questionmark")
                    }
                }
                .padding(Spacing.l)
            }
            .background(Color.groupedBackground)
            .navigationTitle("发送给 AI 的内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { agent.payloadTurnID = nil; dismiss() } label: { Image(systemName: "checkmark") }
                        .tint(.accentFill).accessibilityLabel("完成")
                        .accessibilityIdentifier("payload-done")
                }
            }
            .task(id: agent.payloadTurnID) {
                comparison = nil
                if let payload = agent.payloadTurn?.sentPayload {
                    comparison = await agent.payloadComparison(for: payload)
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var modePicker: some View {
        if typeSize.isAccessibilitySize {
            Picker("查看方式", selection: comparing) {
                Text("发送的内容").tag(false)
                Text("与原始配置对照").tag(true)
            }.pickerStyle(.menu).accessibilityIdentifier("agent-payload-mode")
        } else {
            Picker("查看方式", selection: comparing) {
                Text("发送的内容").tag(false)
                Text("与原始配置对照").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("agent-payload-mode")
        }
    }

    private var comparing: Binding<Bool> {
        Binding(get: { agent.payloadComparing }, set: { agent.payloadComparing = $0 })
    }

    @ViewBuilder private var comparisonContent: some View {
        switch comparison {
        case nil: ProgressView().frame(maxWidth: .infinity).padding()
        case .missing:
            ContentUnavailableView {
                Label("找不到发送时的配置", systemImage: "doc.questionmark")
            } description: {
                Text("这一轮之后分流已经变化，无法重建对照。“发送的内容”仍可查看。")
            }
        case .ready(let result, let exact):
            Text("上方是你的配置（只在本机），下方是 AI 收到的对应内容。")
                .font(.footnote).foregroundStyle(.secondary)
            if !exact {
                StatusBadge(kind: .warning, text: String(localized: "发送后更正过出口地区，对照与实际发送的标签可能略有不同"), font: .footnote)
            }
            Text("原始配置（仅在本机）").font(.subheadline.weight(.semibold))
            AgentCodeBox(text: comparisonText(result, original: true))
                .accessibilityIdentifier("agent-payload-original")
            Text("发送给 AI").font(.subheadline.weight(.semibold))
            AgentCodeBox(text: comparisonText(result, original: false))
                .accessibilityIdentifier("agent-payload-comparison-sent")
        }
    }

    private func comparisonText(_ result: PayloadComparison, original: Bool) -> String {
        AgentStore.filter(result, query: "").map { section in
            ([section.title] + section.rows.map { original ? $0.original : $0.sent } + [section.note].compactMap { $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func sentText(_ payload: AIRequestPayload) -> String {
        var parts = [String(localized: "模型") + ": " + payload.model]
        if let system = payload.system { parts.append(system) }
        if let config = payload.config { parts.append(config) }
        else if !payload.exits.isEmpty { parts.append(payload.exits.joined(separator: "\n")) }
        if !payload.history.isEmpty { parts.append(payload.history.joined(separator: "\n")) }
        parts.append(payload.instruction)
        if let attachments = payload.attachments { parts.append(attachments) }
        if let lookups = payload.lookups { parts.append(lookups) }
        parts.append(contentsOf: payload.checks ?? [])
        return parts.joined(separator: "\n\n")
    }
}

private struct AgentCodeBox: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(text).font(.codeSmall).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.cardBackground, in: .rect(cornerRadius: Radius.codeSheet))
    }
}
