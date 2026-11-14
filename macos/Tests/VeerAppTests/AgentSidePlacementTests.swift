import AppKit
import Testing
@testable import VeerApp

struct AgentSidePlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func sitsFlushAgainstTheWindowsRightEdgeWhenThereIsRoom() {
        let window = CGRect(x: 100, y: 200, width: 1080, height: 720)
        let frame = AgentSidePlacement.frame(parent: window, visible: screen, width: 380, topRow: 52)
        #expect(frame == CGRect(x: 1180, y: 200, width: 380, height: 720))
        // Exactly enough room still counts.
        let snug = CGRect(x: 268, y: 0, width: 1080, height: 720)
        #expect(AgentSidePlacement.frame(parent: snug, visible: screen, width: 380, topRow: 52).minX == 1348)
    }

    @Test func overlapsTheWindowAgainstTheScreenEdgeWithoutRoom() {
        let window = CGRect(x: 400, y: 100, width: 1080, height: 720)
        let frame = AgentSidePlacement.frame(parent: window, visible: screen, width: 380, topRow: 52)
        // Below the window's top row, so its controls stay in view.
        #expect(frame == CGRect(x: 1348, y: 100, width: 380, height: 668))
        #expect(frame.maxX == screen.maxX)
        // A window filling the screen: the panel covers its right side.
        let full = AgentSidePlacement.frame(parent: screen, visible: screen, width: 520, topRow: 52)
        #expect(full == CGRect(x: 1208, y: 0, width: 520, height: 1028))
        #expect(AgentSidePlacement.overlaps(parent: full, visible: screen, width: 520))
        #expect(!AgentSidePlacement.overlaps(parent: CGRect(x: 0, y: 0, width: 800, height: 600), visible: screen, width: 520))
    }

    @Test func followsAWindowOnASecondScreen() {
        let second = CGRect(x: 1728, y: 0, width: 1920, height: 1050)
        let window = CGRect(x: 1800, y: 50, width: 900, height: 600)
        #expect(AgentSidePlacement.frame(parent: window, visible: second, width: 400, topRow: 52) == CGRect(x: 2700, y: 50, width: 400, height: 600))
    }

    @Test func usesTheStoredWidthOnlyWithinItsRange() {
        #expect(AgentSidePlacement.width(320) == 320)
        #expect(AgentSidePlacement.width(450) == 450)
        #expect(AgentSidePlacement.width(520) == 520)
        #expect(AgentSidePlacement.width(200) == 380)
        #expect(AgentSidePlacement.width(900) == 380)
    }
}

struct SnapshotRunTests {
    @Test func quittingASnapshotRunLeavesRealDataAlone() {
        #expect(AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_DIR": "/tmp/x"]))
        #expect(!AppDelegate.isSnapshotRun([:]))
        #expect(!AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_SCENES": "04"]))
    }
}

@MainActor struct AgentSideWindowTests {
    @Test func detachingHidesThePanelAndReattachingRestoresIt() throws {
        let store = SnapshotRunner.sample()
        let controller = AgentSideWindowController()
        controller.store = store
        controller.agent = AgentStore(proxy: store, persist: false)
        let parent = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 860, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer {
            controller.setPresented(false, animated: false)
            controller.attach(to: nil)
            parent.orderOut(nil)
        }
        controller.attach(to: parent)
        controller.setPresented(true, animated: false)
        let panel = try #require(parent.childWindows?.first)
        controller.attach(to: nil)
        #expect(panel.parent == nil)
        #expect(!panel.isVisible)
        // The saved request survives detachment, but the panel must not remain on the old parent.
        controller.attach(to: parent)
        let restored = try #require(parent.childWindows?.first)
        #expect(parent.childWindows?.count == 1)
        #expect(restored.parent === parent)
        #expect(restored.isVisible)
        #expect(restored.undoManager === parent.undoManager)
    }

    @Test func closingTheParentRemovesItsPanelWithoutChangingThePreference() throws {
        let store = SnapshotRunner.sample()
        store.agentPanel = true
        let controller = AgentSideWindowController()
        controller.store = store
        controller.agent = AgentStore(proxy: store, persist: false)
        let parent = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 860, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer {
            controller.setPresented(false, animated: false)
            controller.attach(to: nil)
            parent.orderOut(nil)
        }
        controller.attach(to: parent)
        controller.setPresented(true, animated: false)
        let panel = try #require(parent.childWindows?.first)
        parent.close()
        #expect(panel.parent == nil)
        #expect(!panel.isVisible)
        #expect(store.agentPanel)
    }
}
