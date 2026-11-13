import Foundation
import Testing
@testable import VeerMac

@Test @MainActor func reviewCloseKeepsSelectedIdentityButImportCanReset() {
    let id = UUID()
    var state = ConversationReviewState()
    state.open(id)
    #expect(state.isPresented && state.selectedTurnID == id)
    state.close()
    #expect(!state.isPresented && state.selectedTurnID == id)
    state = ConversationReviewState()
    #expect(!state.isPresented && state.selectedTurnID == nil)
}

@Test @MainActor func routeDisclosuresAreTurnScopedAndDoNotAffectPreviewState() {
    let model = EditorModel()
    let first = ConversationTurn(prompt: "Netflix go jp", mode: "local", fileName: "test.yaml", groups: [])
    let second = ConversationTurn(prompt: "Netflix go hk", mode: "local", fileName: "test.yaml", groups: [])
    model.conversation = [first, second]
    let group = RoutingReviewGroup.ID(service: "Netflix", target: "日本出口", kind: "add_rule")
    model.setRouteDisclosure(first.id, group: group, expanded: true)
    #expect(model.conversation[0].expandedRoutes.contains(group))
    #expect(model.conversation[1].expandedRoutes.isEmpty)
    model.setRouteDisclosure(first.id, group: group, expanded: false)
    #expect(model.conversation[0].expandedRoutes.isEmpty)
    #expect(model.conversation[0].state == .preparing)
    model.openReview(first.id) // No received preview: cannot select a fabricated result.
    #expect(!model.review.isPresented)
    model.confirmTurn(first.id)
    model.discardTurn(first.id)
    model.undoTurn(first.id)
    #expect(model.conversation[0].state == .preparing)
}

@Test @MainActor func reviewWidthRemainsBoundedAndFitsSplitThreshold() {
    #expect(WorkbenchStyle.reviewWidth(in: 1000) >= WorkbenchStyle.reviewMinimum)
    #expect(WorkbenchStyle.reviewWidth(in: 2000) <= WorkbenchStyle.reviewMaximum)
    #expect(WorkbenchStyle.reviewSplitThreshold - WorkbenchStyle.reviewWidth(in: WorkbenchStyle.reviewSplitThreshold) - EditorLayout.section >= EditorLayout.paneMinimum)
}
