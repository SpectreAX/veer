import Testing
@testable import VeerApp

/// Log lines stack their time and level above the message when the list is narrow, and keep one
/// arrangement through a panel's motion.
struct LogsLayoutTests {
    @Test func stacksBelowTheThresholdAtRest() {
        #expect(LogsView.stacks(width: 280, motion: nil))
        #expect(LogsView.stacks(width: LogsView.stackedBelow - 1, motion: nil))
        #expect(!LogsView.stacks(width: LogsView.stackedBelow, motion: nil))
        #expect(!LogsView.stacks(width: 1600, motion: nil))
    }

    @Test func aMotionTakesTheArrangementOfItsNarrowerEnd() {
        // The Agent panel opening from 760 to 380: stacked from the start, not halfway.
        #expect(LogsView.stacks(width: 760, motion: PanelMotion(id: 1, widthChange: -380)))
        // Closing from 380 to 760: stays stacked until it is at rest.
        #expect(LogsView.stacks(width: 380, motion: PanelMotion(id: 2, widthChange: 380)))
        // Both ends wide enough: one row throughout.
        #expect(!LogsView.stacks(width: 1000, motion: PanelMotion(id: 3, widthChange: -380)))
    }
}
