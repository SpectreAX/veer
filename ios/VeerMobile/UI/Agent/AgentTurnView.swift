import SwiftUI
import VeerCore

struct AgentTurnView: View {
    @Environment(AgentStore.self) private var agent
    @Environment(AppModel.self) private var model
    let turn: Turn
    @State private var stepsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if case .note(let text) = turn.outcome {
                Label(text, systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    Text(turn.prompt).font(.body).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.userBubble, in: .rect(cornerRadius: 20))
                        .containerRelativeFrame(.horizontal, count: 9, span: 7, spacing: 0, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if FixtureAI.isFixture(turn) {
                    StatusBadge(kind: .info, text: FixtureAI.label, font: .footnote)
                        .accessibilityIdentifier("agent-fixture-label")
                } else {
                    // A recorded answer has no model run behind it, so it shows no "AI 解析" row.
                    steps
                }
                if let understanding = turn.understanding, !understanding.isEmpty {
                    Label { Text(understanding).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } icon: {
                        Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent)
                    }
                    .font(.subheadline)
                }
                if let reasoning = turn.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("模型思考") { Text(reasoning).font(.footnote).textSelection(.enabled) }
                        .font(.footnote).foregroundStyle(.secondary)
                }
                outcome
                if turn.proposal == nil, turn.sentPayload != nil, turn.outcome != .running {
                    AgentPayloadLink(turnID: turn.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var steps: some View {
        DisclosureGroup(isExpanded: $stepsExpanded) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(turn.steps) { step in
                    HStack(alignment: .top) {
                        if step.state == .running { ProgressView().controlSize(.small) }
                        else { Image(systemName: stepSymbol(step.state)).foregroundStyle(stepColor(step.state)) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if let detail = step.detail { Text(detail).foregroundStyle(.secondary) }
                        }
                    }
                    .font(.footnote).accessibilityElement(children: .combine)
                    .accessibilityValue(stepState(step.state))
                }
            }.padding(.top, Spacing.s)
        } label: {
            HStack(spacing: Spacing.s) {
                if turn.outcome == .running { ProgressView().controlSize(.small) }
                Text(stepSummary)
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .accessibilityIdentifier("agent-turn-steps")
    }

    @ViewBuilder private var outcome: some View {
        switch turn.outcome {
        case .running, .note: EmptyView()
        case .proposal(let proposal): AgentProposalView(turn: turn, proposal: proposal)
        case .noChange(let text), .outOfScope(let text): Text(text).font(.subheadline).textSelection(.enabled)
        case .clarification(let text, let suggestions):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(text)
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { agent.composerText = suggestion; agent.composerFocusToken += 1 }
                        .frame(minHeight: 44)
                }
            }
        case .clarify(let question, let options):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(question)
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.label) { agent.composerText = option.prompt ?? option.label; agent.composerFocusToken += 1 }
                        .frame(minHeight: 44)
                }
            }
        case .failure(let message, let opensSettings, let canUseLocal):
            VStack(alignment: .leading, spacing: Spacing.s) {
                StatusBadge(kind: .failure, text: message, font: .subheadline)
                AgentFlowLayout(spacing: Spacing.s) {
                    if opensSettings {
                        Button("打开设置") { model.showingSettings = true }
                            .buttonStyle(.borderedProminent).tint(.accentFill).frame(minHeight: 44)
                            .accessibilityIdentifier("agent-error-settings")
                    }
                    if canUseLocal {
                        Button("改用本地解析") { agent.retry(turnID: turn.id, useLocal: true) }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                            .accessibilityIdentifier("agent-error-local")
                    }
                    Button("重试") { agent.retry(turnID: turn.id) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("agent-retry")
                }
                .disabled(agent.isRunning || agent.isArchived)
            }
            .padding(Spacing.l)
            .background(Color.cardBackground, in: .rect(cornerRadius: Radius.proposal))
        case .cancelled: Text("已停止。分流没有变化。").font(.subheadline).foregroundStyle(.secondary)
        case .runtime(let run):
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(run.items) { item in
                    StatusBadge(kind: item.state == .failed ? .failure : item.state == .done ? .success : .info,
                                text: item.result ?? item.step.summary, font: .subheadline)
                }
                if run.canUndo {
                    Button("撤销") { agent.undoRuntime(turnID: turn.id) }.frame(minHeight: 44)
                        .accessibilityIdentifier("agent-runtime-undo")
                }
            }
        }
    }

    private var stepSummary: String {
        let label = turn.mode == .local ? String(localized: "本地解析") : String(localized: "AI 解析")
        if turn.outcome == .running { return turn.mode == .local ? label : String(localized: "AI 解析中…") }
        return label + (turn.duration.map { String(format: String(localized: " · %.1f 秒"), $0) } ?? "")
    }
    private func stepSymbol(_ state: Turn.Step.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle"
        case .waiting, .running: "circle"
        }
    }
    private func stepColor(_ state: Turn.Step.State) -> Color {
        switch state { case .done: .veerAccent; case .failed: .statusFailure; default: .secondary }
    }
    private func stepState(_ state: Turn.Step.State) -> String {
        switch state {
        case .done: String(localized: "完成")
        case .failed: String(localized: "失败")
        case .cancelled: String(localized: "已取消")
        case .running: String(localized: "进行中")
        case .waiting: String(localized: "等待")
        }
    }
}
