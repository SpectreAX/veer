import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VeerApp

struct SplitDetailLayoutTests {
    @MainActor @Test func sidebarLabelsDoNotImposeTheirRestingWidthOnACollapsingNativeColumn() {
        let view = NSHostingView(rootView: SidebarRevealLayout(width: 200) {
            Color.clear.frame(minWidth: 200, minHeight: 100)
        })
        #expect(view.fittingSize.width == 0)
    }

    @MainActor @Test func theViewportDoesNotAdvertiseItsCurrentWidthAsANativeMinimum() {
        let view = NSHostingView(rootView: VisibleDetailLayout(width: 860) {
            Color.clear.frame(minWidth: 640, minHeight: 100)
        })
        #expect(view.fittingSize.width < 180)
    }

    @Test func pagesStayWithinTheSplitWhileTheNativeColumnUsesItsDestinationWidth() {
        // Show, interrupt and reverse: the native proposal may still be 1080 throughout.
        let positions: [CGFloat] = [0, 4, 38, 106, 145, 127, 60, 12, 0, 44, 130, 200]
        for leading in positions {
            let width = SplitDetailLayout.visibleWidth(proposed: 1080, split: 1080, leading: leading)
            #expect(leading + width <= 1080)
            #expect(width >= 880)
        }
    }

    @Test func anAgentPanelAndAResizedSidebarUseTheSplitAreaOnly() {
        let width = SplitDetailLayout.visibleWidth(proposed: 700, split: 700, leading: 260)
        #expect(width == 440)
        #expect(width + 260 + 380 == 1080)
    }

    @Test func initialAndTransientGeometryCannotGiveANegativeOrLargerThanProposedWidth() {
        #expect(SplitDetailLayout.visibleWidth(proposed: 0, split: 1080, leading: 200) == 0)
        #expect(SplitDetailLayout.visibleWidth(proposed: 500, split: 700, leading: -10) == 500)
        #expect(SplitDetailLayout.visibleWidth(proposed: 500, split: 700, leading: 701) == 0)
        #expect(SplitDetailLayout.visibleWidth(proposed: 880, split: 1080, leading: 0) == 880)
    }
}
