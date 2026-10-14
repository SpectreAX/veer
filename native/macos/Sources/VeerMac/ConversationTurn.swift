import Foundation
import VeerEditor

struct ConversationTurn: Identifiable {
    enum State: String {
        case preparing, requesting, reviewing, pending, confirmed, unchanged, failed, cancelled, discarded, superseded, undone
        var title: String {
            switch self {
            case .preparing: "准备请求"
            case .requesting: "Thinking…"
            case .reviewing: "检查返回结果"
            case .pending: "候选修改 · 尚未写入"
            case .confirmed: "已确认到草稿"
            case .unchanged: "无需修改"
            case .failed: "处理失败"
            case .cancelled: "已取消"
            case .discarded: "已放弃"
            case .superseded: "已失效 · 输入或草稿已变化"
            case .undone: "已撤销"
            }
        }
        var isRunning: Bool { self == .preparing || self == .requesting || self == .reviewing }
    }
    let id = UUID()
    let startedAt = Date()
    let prompt: String
    let mode: String
    let fileName: String
    let groups: [StrategyGroup]
    var state: State = .preparing
    var steps: [String] = []
    var preview: Preview?
    var diffLines: [ConversationDiffLine] = []
    var message = ""
    var undoToken: UUID?
    var showsSteps = false
    var showsDiff = false
    var expandedRoutes: Set<RoutingReviewGroup.ID> = []
    mutating func invalidate() {
        guard state == .pending else { return }
        state = .superseded
        message = "输入或草稿已变化，此候选未写入。请重新生成。"
    }
}

struct ConversationReviewState {
    var isPresented = false
    var selectedTurnID: UUID?
    mutating func open(_ id: UUID?) { selectedTurnID = id; isPresented = true }
    mutating func close() { isPresented = false }
}

struct ConversationDiffLine: Identifiable {
    let id: Int
    let kind: String
    let text: String
    let before: Int?
    let after: Int?
}

func conversationDiffLines(_ parts: [DiffPart]) -> [ConversationDiffLine] {
    var before = 1, after = 1
    var rows: [ConversationDiffLine] = []
    for part in parts {
        var lines = part.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for text in lines {
            rows.append(.init(id: rows.count, kind: part.kind, text: text, before: part.kind == "add" ? nil : before, after: part.kind == "remove" ? nil : after))
            if part.kind != "add" { before += 1 }
            if part.kind != "remove" { after += 1 }
        }
    }
    return rows
}
