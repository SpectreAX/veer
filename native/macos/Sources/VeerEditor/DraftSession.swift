import Foundation

public struct DraftSession: Sendable {
    public private(set) var draft = Draft()
    public private(set) var revision = 0
    public private(set) var preview: Preview?
    private var history: [(id: UUID, draft: Draft)] = []
    public var undoToken: UUID? { history.last?.id }
    private var manualEditing = false
    private var exportedRules = Draft().rules
    private var imported = false
    private var importedGroups: [StrategyGroup] = []
    public init() {}
    public var canUndo: Bool { !history.isEmpty }
    public var canConfirm: Bool { preview?.changed == true && preview?.validation.status != "failed" }
    public var hasUnsavedChanges: Bool { draft.rules != exportedRules || (imported ? draft.groups != importedGroups : !draft.groups.isEmpty) }
    public mutating func loadDocument(_ newDraft: Draft) {
        draft = newDraft; exportedRules = newDraft.rules; imported = true
        importedGroups = newDraft.groups
        history.removeAll(); manualEditing = false; invalidate()
    }
    public mutating func markRulesExported(_ rules: String) { exportedRules = rules }

    public mutating func invalidate() { revision += 1; preview = nil }
    private mutating func remember() {
        history.append((UUID(), draft))
        if history.count > 20 { history.removeFirst() }
    }
    public mutating func replace(_ newDraft: Draft) {
        guard newDraft != draft else { return }
        remember(); draft = newDraft; manualEditing = false; invalidate()
    }
    public mutating func editRules(_ rules: String) {
        guard rules != draft.rules else { return }
        if !manualEditing { remember(); manualEditing = true }
        draft.rules = rules; invalidate()
    }
    public mutating func endEditing() { manualEditing = false }
    @discardableResult public mutating func receive(_ result: Preview, revision expected: Int) -> Bool {
        guard expected == revision else { return false }
        preview = result; return true
    }
    @discardableResult public mutating func confirm() -> Bool {
        guard canConfirm, let preview else { return false }
        replace(Draft(groups: draft.groups, rules: preview.candidate)); return true
    }
    @discardableResult public mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        draft = previous.draft; manualEditing = false; invalidate(); return true
    }
}
