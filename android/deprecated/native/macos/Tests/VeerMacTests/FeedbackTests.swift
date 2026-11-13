import Testing
import Foundation
import VeerEditor
@testable import VeerMac

@Test @MainActor func oldToastCannotClearNewFeedbackOrBusyState() {
    let model = EditorModel()
    #expect(model.status.isEmpty)
    model.status = "第一条提示"
    let old = model.statusGeneration
    model.status = "第二条提示"
    model.dismissStatus(generation: old)
    #expect(model.status == "第二条提示")
    let current = model.statusGeneration
    model.busy = true
    model.dismissStatus(generation: current)
    #expect(model.status == "第二条提示")
    model.busy = false
    model.dismissStatus(generation: current)
    #expect(model.status.isEmpty)
}

@Test @MainActor func repeatingSameFeedbackRestartsItsLifetime() {
    let model = EditorModel()
    model.status = "已撤销"
    let old = model.statusGeneration
    model.status = "已撤销"
    #expect(model.statusGeneration > old)
    model.dismissStatus(generation: old)
    #expect(model.status == "已撤销")
}

@Test @MainActor func dismissingToastPreservesInlineRecovery() {
    let model = EditorModel()
    model.isError = true
    model.issue = "出口未登记，请先添加策略组。"
    model.status = model.issue!
    model.dismissStatus(generation: model.statusGeneration)
    #expect(model.status.isEmpty)
    #expect(model.issue == "出口未登记，请先添加策略组。")
}

@Test @MainActor func navigationAndTypingPreserveDraftAndPreviewRevision() {
    let model = EditorModel()
    model.setRules("rules:\n  - MATCH,DIRECT\n")
    let revision = model.session.revision
    model.section = .rules
    model.section = .groups
    model.section = .editor
    #expect(model.session.draft.rules == "rules:\n  - MATCH,DIRECT\n")
    #expect(model.session.revision == revision)
    // Typing the next prompt keeps a pending candidate reviewable; only sending supersedes it.
    model.prompt = "Netflix go hk"
    #expect(model.session.revision == revision)
}

@Test @MainActor func appearanceAndNavigationMatchNativePrototype() {
    #expect(EditorAppearance.system.scheme == nil)
    #expect(EditorAppearance.light.scheme != EditorAppearance.dark.scheme)
    #expect(WorkbenchSection.allCases.map(\.title) == ["AI 工作台", "规则稿", "策略组", "AI 设置"])
}

@Test @MainActor func appearanceClickAlwaysSwitchesToOppositeVisibleTheme() {
    #expect(EditorAppearance.system.toggled(resolvedScheme: .dark) == .light)
    #expect(EditorAppearance.system.toggled(resolvedScheme: .light) == .dark)
    #expect(EditorAppearance.light.toggled(resolvedScheme: .dark) == .dark)
    #expect(EditorAppearance.dark.toggled(resolvedScheme: .light) == .light)
}

@Test @MainActor func serviceReviewKeepsDistinctDestinationsAndAllMatches() throws {
    let json = #"{"candidate":"rules: []","summaries":[{"kind":"add_rule","matchType":"DOMAIN-SUFFIX","match":"netflix.com","target":"日本出口","before":[],"after":null},{"kind":"add_rule","matchType":"DOMAIN-SUFFIX","match":"nflxvideo.net","target":"日本出口","before":[],"after":null},{"kind":"add_rule","matchType":"DOMAIN-SUFFIX","match":"netflix.net","target":"香港出口","before":[],"after":null},{"kind":"add_rule","matchType":"DOMAIN-SUFFIX","match":"chatgpt.com","target":"美国出口","before":[],"after":null}],"warnings":[],"diff":[],"changed":true,"validation":{"status":"passed","message":"test"}}"#
    let preview = try JSONDecoder().decode(Preview.self, from: Data(json.utf8))
    let groups = routingReviewGroups(preview.summaries)
    #expect(groups.count == 3)
    #expect(groups[0].id.service == "Netflix")
    #expect(groups[0].changes.count == 2)
    #expect(groups[1].id.target == "香港出口")
    #expect(groups[2].id.service == "ChatGPT")
    #expect(groups.flatMap(\.changes).count == 4)
}
