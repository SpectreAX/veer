import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// The Agent's app-routing proposals (`AppRoutingProposal`): checked by the bundled core, applied
/// as the turn's execution mode allows, saved in the profile's app rules, and undone from the card or
/// the Edit menu.
extension AgentStore {
    private func appProposal(_ sessionID: UUID, _ turnID: UUID) -> AppRoutingProposal? {
        guard let turn = sessions.first(where: { $0.id == sessionID })?.turns.first(where: { $0.id == turnID }),
              case .appRouting(let proposal) = turn.outcome else { return nil }
        return proposal
    }

    private func updateAppProposal(_ sessionID: UUID, _ turnID: UUID, _ change: (inout AppRoutingProposal) -> Void) {
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            guard case .appRouting(var proposal) = turn.outcome else { return }
            change(&proposal)
            turn.outcome = .appRouting(proposal)
        }
    }

    /// What the rules would be after the proposal, and the core's check of the config they make.
    func checkAppRouting(sessionID: UUID, turnID: UUID) {
        guard let proposal = appProposal(sessionID, turnID), let profileID = proposal.profileID else { return }
        let proxy = proxy
        Task {
            let next = proposal.applying(to: proxy.appRules(of: profileID))
            let validation: ValidationResult
            do {
                validation = try await proxy.checkAppRules(next, for: profileID).1
            } catch {
                validation = ValidationResult(status: .failed, message: proxy.message(for: error))
            }
            updateAppProposal(sessionID, turnID) { $0.validation = validation }
            guard let turn = sessions.first(where: { $0.id == sessionID })?.turns.first(where: { $0.id == turnID }),
                  turn.attachments?.isEmpty != false,
                  (turn.executionMode ?? .manual).appliesAppRoutingAutomatically(proposal.changes, validation: validation) else { return }
            applyAppRouting(sessionID: sessionID, turnID: turnID)
            mutateTurn(sessionID: sessionID, turnID: turnID) { $0.autoWritten = true }
        }
    }

    func canApplyAppRouting(_ proposal: AppRoutingProposal) -> Bool {
        proposal.status == .pending && proposal.validation.map { $0.status != .failed } == true && proposal.profileID != nil && !isArchived
    }

    func applyAppRouting(sessionID: UUID? = nil, turnID: UUID) {
        guard let sessionID = sessionID ?? current?.id, let proposal = appProposal(sessionID, turnID), canApplyAppRouting(proposal),
              let profileID = proposal.profileID else { return }
        let proxy = proxy
        Task {
            let previous = proxy.appRules(of: profileID)
            let next = proposal.applying(to: previous)
            do {
                try await proxy.setAppRules(next, for: profileID, undo: NSApp.mainWindow?.undoManager, actionName: String(localized: "应用分流修改"))
                let live = proxy.isRunning && proxy.activeProfileID == profileID
                updateAppProposal(sessionID, turnID) {
                    $0.status = .applied
                    $0.previous = previous
                    $0.message = live ? String(localized: "已保存并生效；应用现有的连接保持原路线，可以在卡片上重新连接。")
                        : String(localized: "已保存，下次启动内核时生效。")
                }
                showToast(String(localized: "已应用 \(proposal.changes.count) 项应用分流修改"), undoable: false)
                announce(String(localized: "已应用"))
            } catch {
                updateAppProposal(sessionID, turnID) {
                    $0.status = .failed
                    $0.message = proxy.message(for: error)
                }
            }
        }
    }

    func undoAppRouting(turnID: UUID) {
        guard let sessionID = current?.id, let proposal = appProposal(sessionID, turnID), proposal.status == .applied,
              let previous = proposal.previous, let profileID = proposal.profileID else { return }
        let proxy = proxy
        Task {
            do {
                try await proxy.setAppRules(previous, for: profileID)
                updateAppProposal(sessionID, turnID) { $0.status = .undone }
            } catch {
                updateAppProposal(sessionID, turnID) { $0.message = proxy.message(for: error) }
            }
        }
    }

    func discardAppRouting(turnID: UUID) {
        guard let sessionID = current?.id else { return }
        updateAppProposal(sessionID, turnID) { if $0.status == .pending { $0.status = .discarded } }
    }

    /// Moves the open connections of the proposal's apps to their new rules.
    func reconnectApps(of proposal: AppRoutingProposal) {
        let proxy = proxy
        Task { for change in proposal.changes { await proxy.reconnect(change.app) } }
    }
}

/// An app-routing proposal: each app, where it goes now and after, the check, and its actions.
struct AppRoutingProposalView: View {
    @Environment(AgentStore.self) private var store
    @Environment(ProxyStore.self) private var proxy
    let turn: Turn
    let proposal: AppRoutingProposal

    private var current: [String: AppRule] {
        guard let id = proposal.profileID else { return [:] }
        let rules = proposal.status == .applied ? (proposal.previous ?? []) : proxy.appRules(of: id)
        return Dictionary(rules.map { ($0.app.root, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            let current = current
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(proposal.changes) { change in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        AppIcon(path: change.app.root, size: 20)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(change.app.name).fontWeight(.medium)
                            Text(summary(change, now: current[change.app.root])).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if change.app.sharesProcesses {
                                StatusBadge(kind: .warning, text: String(localized: "部分流量来自共享的系统进程，不受这条规则控制"), compact: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(padding: 0)
            if let validation = proposal.validation {
                StatusBadge(kind: StatusKind(validation.status), text: validation.status == .passed
                    ? String(localized: "Mihomo 检查通过") : validation.message, compact: true)
                    .help(validation.detail ?? "")
            } else if proposal.status == .pending {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在用 Mihomo 检查…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if case .notRuleMode = proxy.appRoutingGate {
                StatusBadge(kind: .warning, text: String(localized: "现在不是规则模式，应用后也要切回规则模式才起作用"), compact: true)
            }
            if let message = proposal.message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            actions.font(.callout)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Spacing.md) {
            switch proposal.status {
            case .pending:
                Button(String(localized: "应用")) { store.applyAppRouting(turnID: turn.id) }
                    .primaryAction(.regular)
                    .disabled(!store.canApplyAppRouting(proposal))
                Button(String(localized: "放弃")) { store.discardAppRouting(turnID: turn.id) }.secondaryAction()
            case .applied:
                StatusBadge(kind: .success, text: turn.autoWritten == true ? String(localized: "已按执行模式自动应用") : String(localized: "已应用"))
                Button(String(localized: "撤销")) { store.undoAppRouting(turnID: turn.id) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                    .disabled(store.isArchived)
                if proxy.isRunning {
                    Button(String(localized: "重新连接这些应用")) { store.reconnectApps(of: proposal) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
            case .undone: StatusBadge(kind: .neutral, text: String(localized: "已撤销"))
            case .discarded: StatusBadge(kind: .neutral, text: String(localized: "已放弃"))
            case .failed: StatusBadge(kind: .failure, text: String(localized: "没有应用"))
            }
            if turn.sentPayload != nil {
                Button(String(localized: "查看发送给 AI 的内容")) { store.payloadTurnID = turn.id }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
            }
        }
    }

    private func summary(_ change: AppRouteChange, now rule: AppRule?) -> String {
        let before = rule.map { $0.enabled ? $0.target.title : String(localized: "已停用") } ?? String(localized: "按配置的规则")
        if change.remove { return String(localized: "删除这个应用的规则（现在：\(before)）") }
        var text = String(localized: "\(before) → \(change.target?.title ?? before)")
        if !change.domains.isEmpty {
            text += "\n" + change.domains.map { "\($0.value) → \($0.target.title)" }.joined(separator: "\n")
        }
        return text
    }
}
