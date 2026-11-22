import Foundation
import SwiftUI
import VeerUI

/// An undo or redo of a routing change, from the click to the running core. "Undone" is said only
/// when the core has it, or when there is no running core for it to reach, in which case the
/// message says so; a refusal is said as one.
enum ReversalState: Equatable {
    case idle
    case undoing
    case redoing
    case completed(redo: Bool)
    case failed(String)

    var isWorking: Bool { self == .undoing || self == .redoing }
}

extension AgentStore {
    /// How long "done" stays on the button before it goes back to its symbol.
    static let reversalLinger: Duration = .milliseconds(1500)

    func setReversal(_ state: ReversalState) {
        reversalReset?.cancel()
        reversal = state
        switch state {
        case .completed, .failed:
            reversalReset = Task { [weak self] in
                try? await Task.sleep(for: state == .completed(redo: true) || state == .completed(redo: false) ? Self.reversalLinger : .seconds(4))
                guard !Task.isCancelled else { return }
                self?.reversal = .idle
                self?.reversingTurnID = nil
            }
        default: break
        }
    }

    /// Waits for the change to reach the core, then says what happened.
    func reportReversal(redo: Bool, sessionID: UUID, turnID: UUID, apply: Task<ProxyStore.LayerApplied, Never>?, selectNode: () async -> String?) async {
        reversingTurnID = turnID
        setReversal(redo ? .redoing : .undoing)
        switch await apply?.value ?? .saved {
        case .running:
            let error = await selectNode()
            let done = redo ? String(localized: "已重新应用这项修改。") : String(localized: "已撤销这项修改，分流恢复到之前的状态。")
            finishReversal(error ?? done, redo: redo, sessionID: sessionID, warning: error != nil)
        case .saved:
            let done = redo ? String(localized: "已重做，下次使用该配置时生效") : String(localized: "已撤销，下次使用该配置时生效")
            finishReversal(done, redo: redo, sessionID: sessionID)
        case .refused(let reason):
            let text = redo ? String(localized: "重做已保存，但内核没有重新载入：\(reason)") : String(localized: "撤销已保存，但内核没有重新载入：\(reason)")
            finishReversal(text, redo: redo, sessionID: sessionID, warning: true)
        }
    }

    func finishReversal(_ message: String, redo: Bool, sessionID: UUID, warning: Bool = false) {
        setReversal(warning ? .failed(message) : .completed(redo: redo))
        recordReversal(message, in: sessionID, warning: warning)
        showToast(message, warning: warning, recordedIn: sessionID)
        announce(message)
    }
}

/// The undo button's symbol: the arrow at rest, a spinner while the change reaches the core, a
/// check once it has, a warning if it did not. Drawn over the arrow's own space, so the button never
/// changes size.
struct ReversalIcon: View {
    let state: ReversalState

    var body: some View {
        Image(systemName: "arrow.uturn.backward")
            .opacity(state == .idle ? 1 : 0)
            .overlay {
                switch state {
                case .idle: EmptyView()
                case .undoing, .redoing: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .completed: Image(systemName: "checkmark").foregroundStyle(Color.veerAccent)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(StatusKind.warning.color)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The toolbar's undo button, the same in the panel, the Agent page and the Agent window.
struct UndoChangeButton: View {
    @Environment(AgentStore.self) private var agent

    var body: some View {
        Button { agent.undo() } label: {
            Label { Text(title) } icon: { ReversalIcon(state: agent.reversal) }
        }
        .help(help)
        .disabled(!agent.canUndo)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch agent.reversal {
        case .idle: String(localized: "撤销修改")
        case .undoing: String(localized: "正在撤销…")
        case .redoing: String(localized: "正在重做…")
        case .completed(true): String(localized: "已重做")
        case .completed(false): String(localized: "已撤销")
        case .failed: String(localized: "操作未完成")
        }
    }

    private var help: String {
        if case .failed(let reason) = agent.reversal { return reason }
        return agent.reversal == .idle ? String(localized: "撤销这个对话里最近应用的修改") : title
    }
}

/// "Undo" / "Redo" in a turn, as wide as its longest state, saying when it is under way.
struct ReversalLink: View {
    @Environment(AgentStore.self) private var agent
    let turnID: UUID
    let redo: Bool
    let action: () -> Void

    var body: some View {
        let working = agent.reversal.isWorking && agent.reversingTurnID == turnID
        Button(action: action) {
            ZStack(alignment: .leading) {
                // The widest text holds the width, so the row does not move as the state changes.
                Text(redo ? String(localized: "正在重做…") : String(localized: "正在撤销…")).hidden()
                Text(working ? (redo ? String(localized: "正在重做…") : String(localized: "正在撤销…"))
                     : (redo ? String(localized: "重做") : String(localized: "撤销")))
            }
        }
        .buttonStyle(.link)
        .foregroundStyle(Color.veerAccent)
        .disabled(agent.isReversing)
    }
}
