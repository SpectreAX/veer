import Testing
@testable import VeerUI

@MainActor struct ColumnRevealTests {
    @Test func startsWhereItIsAsked() {
        #expect(ColumnReveal(visible: true).progress == 1 && ColumnReveal(visible: true).reservesSpace)
        #expect(ColumnReveal().progress == 0 && !ColumnReveal().reservesSpace)
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
        // The page keeps its width while the column slides over it.
        #expect(!reveal.reservesSpace)
        reveal.jump(to: true)
        #expect(!reveal.isAnimating && reveal.progress == 1 && reveal.reservesSpace)
        // Going away, the page takes its room back at once, under the column.
        reveal.animate(to: false, reduceMotion: false)
        #expect(reveal.isAnimating && !reveal.reservesSpace && reveal.progress == 1)
        reveal.jump(to: false)
        // Already there: nothing to animate.
        reveal.animate(to: false, reduceMotion: false)
        #expect(!reveal.isAnimating && !reveal.reservesSpace)
    }
}
