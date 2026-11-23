import SwiftUI
import Testing
@testable import VeerUI

/// Reduce Motion: what moves or resizes switches at once (DESIGN_SPEC, Motion).
struct MotionTests {
    @Test func anAnimationIsDroppedOnlyWithReduceMotion() {
        #expect(Motion.unlessReduced(Motion.standard, true) == nil)
        #expect(Motion.unlessReduced(Motion.standard, false) == Motion.standard)
        #expect(Motion.unlessReduced(Motion.toolbar, false) == Motion.toolbar)
    }
}
