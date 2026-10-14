import Foundation
import Testing
@testable import VeerEditor

private func preview(status: String = "passed", changed: Bool = true) throws -> Preview {
    let object: [String: Any] = ["candidate": "rules:\n  - DOMAIN-SUFFIX,example.com,DIRECT\n", "summaries": [], "warnings": [], "diff": [], "changed": changed, "validation": ["status": status, "message": "placeholder"]]
    return try JSONDecoder().decode(Preview.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func staleResultsCannotConfirm() throws {
    var state = DraftSession()
    let old = state.revision
    state.editRules("rules: [] # edit\n")
    #expect(!state.receive(try preview(), revision: old))
    #expect(state.confirm() == false)
    #expect(state.receive(try preview(), revision: state.revision))
    state.invalidate()
    #expect(state.confirm() == false)
}

@Test func confirmUndoAndFailedValidation() throws {
    var state = DraftSession()
    let original = state.draft
    #expect(state.receive(try preview(status: "failed"), revision: state.revision))
    #expect(state.confirm() == false)
    #expect(state.receive(try preview(changed: false), revision: state.revision))
    #expect(state.confirm() == false)
    #expect(state.receive(try preview(), revision: state.revision))
    #expect(state.confirm() == true)
    #expect(state.draft.rules.contains("example.com"))
    #expect(state.undo() == true)
    #expect(state.draft == original)
    #expect(state.undo() == false)
}

@Test func manualEditsAreOneUndoAndHistoryIsBounded() {
    var state = DraftSession()
    state.editRules("rules: [one]")
    state.editRules("rules: [two]")
    #expect(state.undo() == true)
    #expect(state.draft == Draft())
    for index in 0..<25 { state.replace(Draft(rules: "rules: [\(index)]")) }
    var undone = 0
    while state.undo() { undone += 1 }
    #expect(undone == 20)
}

@Test func exportClearsRuleDirtyStateButDoesNotPretendGroupsAreSaved() {
    var state = DraftSession()
    #expect(!state.hasUnsavedChanges)
    state.editRules("rules: [updated]")
    #expect(state.hasUnsavedChanges)
    state.markRulesExported(state.draft.rules)
    #expect(!state.hasUnsavedChanges)
    state.replace(Draft(groups: [.init(name: "日本出口", region: "JP")], rules: state.draft.rules))
    #expect(state.hasUnsavedChanges)
    state.markRulesExported(state.draft.rules)
    #expect(state.hasUnsavedChanges)
}
