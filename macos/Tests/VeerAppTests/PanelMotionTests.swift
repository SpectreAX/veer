import SwiftUI
import Testing
@testable import VeerApp

@MainActor struct PanelMotionTests {
    @Test func thePanelSaysItIsAboutToChangeOnlyWhenItDoes() {
        let store = SnapshotRunner.sample()
        store.agentPanel = false
        var states: [Bool] = []
        store.agentPanelWillChange = { states.append(store.agentPanel) }
        store.agentPanel = false
        #expect(states.isEmpty)
        store.agentPanel = true
        store.agentPanel = true
        store.agentPanel = false
        // Each time with the state the page still shows.
        #expect(states == [false, true])
    }

    @Test func withoutAWindowThereIsNoPicture() {
        let source = PageSnapshotSource()
        #expect(source.capture(insets: NSEdgeInsets()) == nil)
        source.capturePending(insets: NSEdgeInsets())
        #expect(source.takePending() == nil)
    }
}
