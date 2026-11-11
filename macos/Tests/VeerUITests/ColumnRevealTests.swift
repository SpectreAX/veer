import Testing
@testable import VeerUI

@MainActor struct ColumnRevealTests {
    @Test func startsWhereItIsAsked() {
        #expect(ColumnReveal(visible: true).progress == 1)
        #expect(ColumnReveal().progress == 0)
    }

    @Test func reduceMotionAndJumpsSwitchAtOnce() {
        let reveal = ColumnReveal()
        reveal.animate(to: true, reduceMotion: true)
        #expect(reveal.progress == 1 && !reveal.isAnimating)
        reveal.jump(to: false)
        #expect(reveal.progress == 0 && !reveal.isAnimating)
    }

    @Test func animatingStepsFromWhereItIsAndAJumpStopsIt() {
        let reveal = ColumnReveal()
        reveal.animate(to: true, reduceMotion: false)
        #expect(reveal.isAnimating)
        #expect(reveal.progress == 0)
        reveal.jump(to: true)
        #expect(!reveal.isAnimating && reveal.progress == 1)
        // Already there: nothing to animate.
        reveal.animate(to: true, reduceMotion: false)
        #expect(!reveal.isAnimating)
    }
}
