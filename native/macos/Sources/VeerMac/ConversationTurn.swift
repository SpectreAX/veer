import Foundation
import VeerEditor

nonisolated struct ConversationTurn: Identifiable, Codable {
    enum State: String, Codable {
        case preparing, requesting, reviewing, pending, blocked, clarify, confirmed, unchanged, failed, cancelled, discarded, superseded, undone
        var title: String {
            switch self {
            case .preparing: "准备请求"
            case .requesting: "Thinking…"
            case .reviewing: "检查返回结果"
            case .pending: "待审批 · 尚未写入"
            case .blocked: "校验失败 · 不能写入"
            case .clarify: "需要澄清"
            case .confirmed: "已写入草稿"
            case .unchanged: "无需修改"
            case .failed: "处理失败"
            case .cancelled: "已取消"
            case .discarded: "已全部拒绝"
            case .superseded: "已失效 · 输入或草稿已变化"
            case .undone: "已撤销"
            }
        }
        var isRunning: Bool { self == .preparing || self == .requesting || self == .reviewing }
    }
    var id = UUID()
    var startedAt = Date()
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
    /// Service groups the user rejected; every other group is accepted.
    var rejectedRoutes: Set<RoutingReviewGroup.ID> = []
    mutating func invalidate() {
        guard state == .pending else { return }
        state = .superseded
        message = "输入或草稿已变化，此候选未写入。请重新生成。"
    }
    /// A relaunch cannot resume a request that was in flight.
    mutating func restoreAfterRelaunch() {
        guard state.isRunning else { return }
        state = .cancelled
        message = "应用重新打开，此请求未完成。草稿未改变。"
    }
    var routeGroups: [RoutingReviewGroup] { preview.map { routingReviewGroups($0.summaries) } ?? [] }
    var acceptedRouteCount: Int { routeGroups.filter { !rejectedRoutes.contains($0.id) }.count }
}

struct ConversationReviewState {
    enum Tab: String, CaseIterable, Identifiable {
        case changes, rules, test
        var id: Self { self }
        var title: String {
            switch self { case .changes: "变更"; case .rules: "规则"; case .test: "测试" }
        }
    }
    var isPresented = false
    var selectedTurnID: UUID?
    var tab = Tab.changes
    mutating func open(_ id: UUID?) { selectedTurnID = id; tab = .changes; isPresented = true }
    mutating func show(_ tab: Tab) { self.tab = tab; isPresented = true }
    mutating func close() { isPresented = false }
}

nonisolated struct ConversationDiffLine: Identifiable, Codable {
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

struct LineChangeCount: Equatable {
    var added = 0
    var removed = 0
    var isEmpty: Bool { added == 0 && removed == 0 }
}

func lineChangeCount(_ rows: [ConversationDiffLine]) -> LineChangeCount {
    LineChangeCount(added: rows.filter { $0.kind == "add" }.count, removed: rows.filter { $0.kind == "remove" }.count)
}

/// Rule lines added and removed between two rules YAML texts, e.g. since the last export.
func lineChangeCount(from old: String, to new: String) -> LineChangeCount {
    let lines = { (text: String) in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    var count = LineChangeCount()
    for change in lines(new).difference(from: lines(old)) {
        switch change { case .insert: count.added += 1; case .remove: count.removed += 1 }
    }
    return count
}
