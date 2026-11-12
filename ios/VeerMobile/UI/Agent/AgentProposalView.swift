import SwiftUI
import VeerCore

struct AgentProposalView: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy
    @Environment(\.dynamicTypeSize) private var typeSize
    let turn: Turn
    let proposal: Turn.Proposal

    private var editable: Bool {
        proposal.status == .pending && !agent.isArchived && proposal.baseDraft == agent.current?.draftText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            ForEach(proposal.items) { item in
                changeRow(item)
            }
            if agent.revalidating.contains(turn.id) {
                HStack { ProgressView(); Text("正在按你的选择重新生成并校验…") }
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                validation
            }
            actions
            if let notice = proxy.notice, proposal.status == .pending {
                StatusBadge(kind: .failure, text: notice, font: .footnote)
            }
            if turn.sentPayload != nil { AgentPayloadLink(turnID: turn.id) }
        }
        .padding(14)
        .background(Color.cardBackground, in: .rect(cornerRadius: Radius.proposal))
        .accessibilityIdentifier("agent-proposal")
    }

    private func changeRow(_ item: ChangeItem) -> some View {
        let accepted = proposal.accepted.contains(item.id)
        return HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 5) {
                Label(kindTitle(item.kind), systemImage: kindSymbol(item.kind)).font(.caption).foregroundStyle(.secondary)
                Text(item.targetName.map { "\(item.subject) → \($0)" } ?? item.subject)
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let group = item.group {
                    Text(String(localized: "\(group.members.count) 个成员")).font(.caption).foregroundStyle(.secondary)
                    Text(group.members.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                } else if !item.matchType.isEmpty {
                    Text([item.matchType, item.match].filter { !$0.isEmpty }.joined(separator: ","))
                        .font(.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if item.kind == .moveRule {
                    Text(String(localized: "\(item.rule ?? item.subject) · 移到 \(item.replaced.first ?? "") 之前，规则本身不变"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array((item.kind == .moveRule || item.kind == .groupMembers ? [] : item.replaced).enumerated()), id: \.offset) { _, rule in
                    Text(rule).font(.codeSmall).strikethrough()
                        .foregroundStyle(Color.statusFailure)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.diffRemoved, in: .rect(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable {
                Button { agent.setAccepted(!accepted, item: item.id, turnID: turn.id) } label: {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(accepted ? Color.veerAccent : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "接受") + "，" + item.subject)
                .accessibilityValue(String(format: accepted ? String(localized: "%@，已接受") : String(localized: "%@，已拒绝"), item.subject))
                .accessibilityHint(accepted ? String(localized: "已接受，取消勾选则不写入这一项") : String(localized: "勾选以接受这一项"))
                .accessibilityAddTraits(accepted ? .isSelected : [])
                .accessibilityIdentifier("agent-proposal-toggle-\(item.id)")
            }
        }
        .padding(.leading, Spacing.m).padding(.trailing, editable ? Spacing.xs : Spacing.m).padding(.vertical, 11)
        .background(Color.changeRow, in: .rect(cornerRadius: Radius.change))
        .opacity(accepted || proposal.status != .pending ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private var validation: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(proposal.validation.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: proposal.validation.status == .passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(proposal.validation.status == .passed ? Color.veerAccent : proposal.validation.status == .failed ? Color.statusFailure : Color.statusWarning)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.quietFill, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("agent-validation")
            if let detail = proposal.validation.detail {
                Text(detail).font(.codeSmall).foregroundStyle(Color.statusFailure).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch proposal.status {
        case .pending where editable:
            if typeSize.isAccessibilitySize {
                VStack(spacing: Spacing.s) { applyButton; discardButton }
            } else {
                HStack(spacing: Spacing.s) { applyButton; discardButton }
            }
        case .written:
            HStack {
                StatusBadge(kind: .success, text: String(localized: "已应用"), font: .subheadline)
                Button("撤销") { agent.undo() }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!agent.canUndo || !isLatestWritten)
                    .accessibilityIdentifier("agent-undo")
            }
        case .pending, .stale:
            Button("重试") { agent.retry(turnID: turn.id) }.frame(minHeight: 44)
                .disabled(agent.isRunning || agent.isArchived).accessibilityIdentifier("agent-proposal-retry")
        case .undone, .discarded: EmptyView()
        }
    }

    private var applyButton: some View {
        Button { agent.write(turnID: turn.id) } label: {
            Text(String(localized: "应用 \(proposal.accepted.count) 项"))
        }
        .buttonStyle(.primaryCapsule)
        .disabled(!agent.canWrite(turn))
        .accessibilityIdentifier("agent-apply")
    }
    private var discardButton: some View {
        Button("放弃") { agent.discard(turnID: turn.id) }
            .buttonStyle(.secondaryCapsule).accessibilityIdentifier("agent-discard")
    }
    private var isLatestWritten: Bool { agent.current?.turns.last { $0.proposal?.status == .written }?.id == turn.id }
    private var summary: String {
        switch proposal.status {
        case .pending where !editable: String(localized: "这组修改基于之前的分流生成。")
        case .pending: String(localized: "准备了 \(proposal.items.count) 项分流修改，等待你确认。")
        case .written: String(localized: "已应用 \(proposal.accepted.count) 项修改，记在“我的分流”里。")
        case .undone: String(localized: "这组修改应用后已被撤销。")
        case .discarded: String(localized: "已放弃这组修改，分流没有变化。")
        case .stale: String(localized: "这组修改基于之前的分流生成。")
        }
    }
    private func kindTitle(_ kind: ChangeItem.Kind) -> String {
        switch kind {
        case .group: String(localized: "新建策略组")
        case .moveRule: String(localized: "移动规则")
        case .removeRule: String(localized: "删除规则")
        case .removeProvider: String(localized: "删除规则集")
        case .groupMembers: String(localized: "修改成员")
        case .ruleSet: String(localized: "新增规则集")
        case .route, .addMatch: String(localized: "新增规则")
        }
    }
    private func kindSymbol(_ kind: ChangeItem.Kind) -> String {
        switch kind {
        case .group, .groupMembers: "square.stack"
        case .moveRule: "arrow.up.to.line"
        case .removeRule, .removeProvider: "trash"
        case .route, .ruleSet, .addMatch: "plus"
        }
    }
}

struct AgentPayloadLink: View {
    @Environment(AgentStore.self) private var agent
    let turnID: UUID
    var body: some View {
        Button("查看发送给 AI 的内容") { agent.showPayload(of: turnID) }
            .font(.footnote).frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("agent-payload-link")
    }
}
