import Foundation
import Testing
import VeerEditor
@testable import VeerMac

@Test @MainActor func pendingOnlyInvalidationAndDiffNumbers() throws {
    var turn = ConversationTurn(prompt: "Netflix go jp", mode: "local", fileName: "test.yaml", groups: [])
    turn.state = .confirmed
    turn.invalidate()
    #expect(turn.state == .confirmed)
    turn.state = .pending
    turn.invalidate()
    #expect(turn.state == .superseded)
    let parts = try JSONDecoder().decode([DiffPart].self, from: Data(#"[{"kind":"same","text":"rules:\n"},{"kind":"remove","text":"old\n"},{"kind":"add","text":"new\nnext\n"},{"kind":"same","text":"MATCH,DIRECT"}]"#.utf8))
    let rows = conversationDiffLines(parts)
    #expect(rows.count == 5)
    #expect(rows[1].before == 2 && rows[1].after == nil)
    #expect(rows[2].before == nil && rows[2].after == 2)
    #expect(rows[4].before == 3 && rows[4].after == 4)
}

@MainActor private func waitForOperation(_ model: EditorModel) async throws {
    let deadline = Date().addingTimeInterval(10)
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.busy)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func conversationRealLocalServiceLifecycle() async throws {
    let rawPort = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let port = try #require(Int(rawPort))
    let model = EditorModel(client: try EditorClient(port: port))
    let yaml = "proxy-groups:\n  - name: 日本出口\n    type: select\n    proxies: [DIRECT]\n  - name: 美国出口\n    type: select\n    proxies: [DIRECT]\n  - name: 香港出口\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n"
    try await model.acceptImport(yaml, name: "test.yaml", revision: model.session.revision)
    let original = model.session.draft.rules
    model.prompt = "Netflix 走日本，ChatGPT 走美国"
    model.generate()
    #expect(model.conversation.count == 1)
    #expect(model.prompt.isEmpty)
    try await waitForOperation(model)
    #expect(model.conversation[0].state == .pending)
    #expect(!model.conversation[0].diffLines.isEmpty)
    #expect(model.session.draft.rules == original)
    #expect(model.review.isPresented && model.reviewedTurn?.id == model.conversation[0].id)
    let range = RoutingReviewGroup.ID(service: "Netflix", target: "日本出口", kind: "add_rule")
    model.setRouteDisclosure(model.conversation[0].id, group: range, expanded: true)
    model.review.close()
    model.openReview(model.conversation[0].id)
    #expect(model.conversation[0].expandedRoutes.contains(range))
    model.setDisclosure(model.conversation[0].id, steps: true, diff: true)
    model.confirm()
    #expect(model.conversation[0].state == .confirmed)
    #expect(model.conversation[0].showsDiff)
    let first = model.session.draft.rules
    model.prompt = "Netflix go hk"; model.generate()
    try await waitForOperation(model)
    model.confirm()
    #expect(model.conversation[1].state == .confirmed)
    #expect(!model.canUndoTurn(model.conversation[0].id))
    #expect(model.canUndoTurn(model.conversation[1].id))
    model.openReview(model.conversation[0].id)
    let currentRules = model.session.draft.rules
    model.confirmTurn(model.conversation[0].id)
    model.discardTurn(model.conversation[0].id)
    model.undoTurn(model.conversation[0].id)
    #expect(model.session.draft.rules == currentRules)
    #expect(model.session.draft.rules.contains("netflix.com,香港出口"))
    model.undo()
    #expect(model.conversation[1].state == .undone)
    #expect(model.conversation[0].state == .confirmed)
    #expect(model.session.draft.rules == first)
    model.prompt = "Netflix go hk"; model.generate()
    try await waitForOperation(model)
    model.discard()
    #expect(model.conversation.last?.state == .discarded)
    #expect(model.session.draft.rules == first)
    model.prompt = "Netflix go hk"; model.generate()
    try await waitForOperation(model)
    model.prompt = "ChatGPT go us"
    #expect(model.conversation.last?.state == .superseded)
    #expect(!model.session.canConfirm)
    model.prompt = "Netflix go hk"; model.generate(); model.cancel()
    try await waitForOperation(model)
    #expect(model.conversation.last?.state == .cancelled)
    #expect(model.session.draft.rules == first)
    model.setRules(first + "\n")
    model.undo()
    #expect(model.conversation[0].state == .confirmed)
    #expect(model.session.draft.rules == first)
    model.undo()
    #expect(model.conversation[0].state == .undone)
    #expect(model.session.draft.rules == original)
    model.prompt = "Netflix 走德国"; model.generate()
    try await waitForOperation(model)
    #expect(model.conversation.last?.state == .failed)
    #expect(model.session.draft.rules == original)
    #expect(!model.session.canConfirm)
}
