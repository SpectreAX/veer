import AppKit
import Testing
@testable import VeerUI

@MainActor struct SidebarAnimatorTests {
    @Test func attachmentAndDetachmentPreserveTheNativeColumnsAndRestoreTheirPolicy() {
        let fixture = fixture(), controller = fixture.controller, sidebar = fixture.sidebar, animator = fixture.animator
        #expect(sidebar.collapseBehavior == .useConstraints)
        #expect(sidebar.minimumThickness == 180 && sidebar.maximumThickness == 260)
        #expect(controller.splitViewItems.last?.collapseBehavior == .default)
        animator.toggle(reduceMotion: true)
        #expect(sidebar.isCollapsed && animator.isHidden && animator.nativeHidden && !animator.isAnimating)
        animator.toggle(reduceMotion: true)
        #expect(!sidebar.isCollapsed && !animator.isHidden && !animator.nativeHidden)
        #expect(sidebar.minimumThickness == 180 && sidebar.maximumThickness == 260)
        animator.disconnect()
        #expect(sidebar.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
        animator.toggle(reduceMotion: true)
        #expect(animator.isHidden && animator.nativeHidden)
    }

    @Test func normalAnimationsReachBothEndpointsAndRestoreTheNativeLimits() async throws {
        let fixture = fixture(), controller = fixture.controller, sidebar = fixture.sidebar, animator = fixture.animator
        for hidden in [true, false] {
            animator.toggle(reduceMotion: false)
            animator.startPendingAnimation()
            let deadline = Date().addingTimeInterval(2)
            while animator.isAnimating, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                pumpRunLoop(for: 0.01)
            }
            #expect(!animator.isAnimating && sidebar.isCollapsed == hidden && animator.nativeHidden == hidden)
            #expect(sidebar.minimumThickness == 180 && sidebar.maximumThickness == 260)
            #expect(controller.view.frame.width == 860)
        }
        animator.disconnect()
    }

    @Test func reversingThenDismantlingInvalidatesQueuedAndRunningAnimationWork() async throws {
        let fixture = fixture(), controller = fixture.controller, sidebar = fixture.sidebar, animator = fixture.animator
        animator.toggle(reduceMotion: false)
        animator.startPendingAnimation()
        try await Task.sleep(for: .milliseconds(10))
        pumpRunLoop(for: 0.04)
        animator.toggle(reduceMotion: false)
        animator.startPendingAnimation()
        try await Task.sleep(for: .milliseconds(10))
        pumpRunLoop(for: 0.03)
        animator.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        pumpRunLoop(for: 0.01)
        #expect(!animator.isAnimating && !animator.isHidden && !sidebar.isCollapsed)
        #expect(sidebar.minimumThickness == 180 && sidebar.maximumThickness == 260)
        #expect(sidebar.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
        #expect(controller.view.frame.width == 860)
    }

    private struct Fixture {
        let controller: NSSplitViewController
        let sidebar: NSSplitViewItem
        let animator: SidebarAnimator
    }

    // NSAnimation uses the main run loop. Yield the executor before pumping it so deferred
    // setup on DispatchQueue.main can run, as it does in the app's event loop.
    private func pumpRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func fixture() -> Fixture {
        let controller = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSViewController())
        let detail = NSSplitViewItem(viewController: NSViewController())
        sidebar.viewController.view = NSView()
        detail.viewController.view = NSView()
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 260
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        controller.addSplitViewItem(sidebar)
        controller.addSplitViewItem(detail)
        controller.view.frame = CGRect(x: 0, y: 0, width: 860, height: 560)
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(200, ofDividerAt: 0)
        let animator = SidebarAnimator()
        let connector = SidebarAnimationHost.Connector(animator: animator)
        sidebar.viewController.view.addSubview(connector)
        connector.connect()
        return Fixture(controller: controller, sidebar: sidebar, animator: animator)
    }
}
