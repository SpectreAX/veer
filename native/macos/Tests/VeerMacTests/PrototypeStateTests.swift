import Foundation
import Testing
import VeerEditor
@testable import VeerMac

@Test @MainActor func lineChangesCountRuleInsertionsAndRemovals() {
    let old = "rules:\n  - GEOSITE,cn,DIRECT\n  - DOMAIN-SUFFIX,Netflix.com,HK\n"
    let new = "rules:\n  - DOMAIN-SUFFIX,netflix.com,JP\n  - DOMAIN-SUFFIX,netflix.net,JP\n  - GEOSITE,cn,DIRECT\n"
    #expect(lineChangeCount(from: old, to: new) == LineChangeCount(added: 2, removed: 1))
    #expect(lineChangeCount(from: old, to: old).isEmpty)
}

@Test @MainActor func aiModeNeedsAKeyBeforeSending() {
    let model = EditorModel()
    model.prompt = "Netflix 走日本"
    model.mode = "ai"
    #expect(model.needsKey)
    #expect(!model.canGenerate)
    model.setKey("sk-test-session-only")
    #expect(!model.needsKey)
    model.setKey("")
    model.settings.useSavedKey = true
    #expect(!model.needsKey)
    model.mode = "local"
    model.settings.useSavedKey = false
    #expect(!model.needsKey)
}

@Test @MainActor func reviewOpensOnChangesAndOtherTabsAreSeparate() {
    var state = ConversationReviewState()
    state.show(.rules)
    #expect(state.isPresented && state.tab == .rules)
    state.open(UUID())
    #expect(state.tab == .changes)
}

@Test @MainActor func unexportedChangesTrackManualEditsAndInjectedClientHasNoServiceState() {
    let model = EditorModel(client: try! EditorClient(port: 1))
    #expect(model.serviceState == .idle)
    #expect(model.unexportedChanges.isEmpty)
    model.setRules("rules:\n  - MATCH,DIRECT\n")
    #expect(model.unexportedChanges == LineChangeCount(added: 2, removed: 1)) // "rules: []" becomes two lines
    model.requestExport()
    #expect(model.showingExport)
}

@Test @MainActor func clarificationIsAReplyNotAFailure() {
    #expect(ConversationTurn.State.clarify.title == "需要澄清")
    #expect(!ConversationTurn.State.clarify.isRunning)
    #expect(ConversationTurn.State.blocked.title == "校验失败 · 不能写入")
    #expect(EditorFailure("问题", isClarification: true).isClarification)
    #expect(!EditorFailure("错误").isClarification)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func importedUnknownRegionsCanBeConfirmed() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let port = try #require(Int(raw))
    let model = EditorModel(client: try EditorClient(port: port))
    let yaml = "proxy-groups:\n  - name: 日本出口\n    type: select\n    proxies: [DIRECT]\n  - name: Auto 优选\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n"
    try await model.acceptImport(yaml, name: "regions.yaml", revision: model.session.revision)
    #expect(model.unknownRegionGroups.map(\.name) == ["Auto 优选"])
    model.setRegion("SG", for: "Auto 优选")
    #expect(model.unknownRegionGroups.isEmpty)
}
