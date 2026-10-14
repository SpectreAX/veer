import CryptoKit
import Foundation
import Testing
import VeerEditor
@testable import VeerMac

private struct FixedKey: SessionKeyProvider {
    let value = SymmetricKey(size: .bits256)
    func key() throws -> SymmetricKey { value }
}

private let twoExits = "proxy-groups:\n  - name: 🇯🇵 日本 自动\n    type: select\n    proxies: [DIRECT]\n  - name: 美国出口\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n"

@MainActor private func idle(_ model: EditorModel) async throws {
    let deadline = Date().addingTimeInterval(10)
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.busy)
}

@Test @MainActor func completionTriggersOnlyAtWordStartAndKeepsUTF16Carets() throws {
    #expect(completionTrigger(in: "a@b", caret: 3) == nil)
    #expect(completionTrigger(in: "https://x", caret: 9) == nil)
    let text = "🇯🇵 Netflix @日"
    let trigger = try #require(completionTrigger(in: text, caret: (text as NSString).length))
    #expect(trigger.character == "@" && trigger.query == "日")
    let groups = [StrategyGroup(name: "🇯🇵 日本 自动", region: "JP"), StrategyGroup(name: "美国出口", region: "US")]
    let items = completionItems(for: trigger, groups: groups)
    #expect(items.first?.label == "🇯🇵 日本 自动")
    let result = applyCompletion(items[0], to: text, trigger: trigger)
    #expect(result.text == "🇯🇵 Netflix 🇯🇵 日本 自动 ")
    #expect(result.caret == (result.text as NSString).length)
    let commands = completionItems(for: try #require(completionTrigger(in: "/", caret: 1)), groups: groups)
    #expect(commands.map(\.label) == ["路由", "直连", "屏蔽", "删除", "检查"])
}

@Test @MainActor func checkCommandOpensDomainTestInsteadOfInserting() {
    let model = EditorModel(client: try! EditorClient(port: 1))
    model.prompt = "www.netflix.com /检"
    model.updateCompletion(text: model.prompt, caret: (model.prompt as NSString).length, composing: false)
    #expect(model.completion?.items.first?.label == "检查")
    model.updateCompletion(text: model.prompt, caret: (model.prompt as NSString).length, composing: true)
    #expect(model.completion == nil) // IME composition never opens the menu
    model.updateCompletion(text: model.prompt, caret: (model.prompt as NSString).length, composing: false)
    model.chooseCompletion()
    #expect(model.prompt.isEmpty)
    #expect(model.review.isPresented && model.review.tab == .test)
    #expect(model.testedDomain == "www.netflix.com")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func partialApprovalWritesOnlyAcceptedCardsAndUndoes() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let model = EditorModel(client: try EditorClient(port: try #require(Int(raw))))
    try await model.acceptImport(twoExits, name: "two.yaml", revision: model.session.revision)
    let original = model.session.draft.rules
    model.prompt = "Netflix 走日本，ChatGPT 走美国"
    model.generate()
    try await idle(model)
    let turn = try #require(model.conversation.last)
    #expect(turn.state == .pending && turn.routeGroups.count == 2)
    let chatGPT = try #require(turn.routeGroups.first { $0.id.service == "ChatGPT" }).id
    model.setRoute(chatGPT, accepted: false, in: turn.id)
    #expect(model.conversation.last?.acceptedRouteCount == 1)
    model.applyTurn(turn.id)
    try await idle(model)
    #expect(model.conversation.last?.state == .confirmed)
    #expect(model.session.draft.rules.contains("netflix.com"))
    #expect(!model.session.draft.rules.contains("chatgpt.com"))
    model.refreshRuleList()
    let deadline = Date().addingTimeInterval(5)
    while model.ruleList == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.ruleList?.first?.hasPrefix("DOMAIN-SUFFIX,netflix.com,") == true)
    #expect(RuleMatcher.match(rules: model.ruleList ?? [], domain: "chatgpt.com")?.target == "DIRECT")
    model.undoTurn(turn.id)
    #expect(model.session.draft.rules == original)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func sessionsPersistEncryptedAndResumeAfterRelaunch() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let port = try #require(Int(raw))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-sessions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(url: directory.appendingPathComponent("sessions.bin"), keyProvider: FixedKey())
    let model = EditorModel(client: try EditorClient(port: port), store: store)
    try await model.acceptImport(twoExits, name: "first.yaml", revision: model.session.revision)
    let first = try #require(model.activeSessionID)
    model.prompt = "Netflix 走日本"; model.generate()
    try await idle(model)
    model.applyTurn(try #require(model.conversation.last?.id))
    try await idle(model)
    try await model.acceptImport(twoExits, name: "second.yaml", revision: model.session.revision)
    #expect(model.sessions.map(\.name) == ["second.yaml", "first.yaml"])
    #expect(model.conversation.isEmpty)
    model.switchSession(first)
    #expect(model.importedName == "first.yaml")
    #expect(model.conversation.count == 1 && model.session.draft.rules.contains("netflix.com"))
    #expect(model.session.canUndo)
    model.flushSave()

    let relaunched = EditorModel(client: try EditorClient(port: port), store: store)
    relaunched.loadSessions()
    #expect(relaunched.sessions.count == 2)
    #expect(relaunched.importedName == "first.yaml")
    #expect(relaunched.conversation.first?.state == .confirmed)
    relaunched.deleteSession(try #require(relaunched.sessions.first { $0.name == "second.yaml" }).id)
    relaunched.flushSave()
    #expect(try store.load().map(\.name) == ["first.yaml"])
}
