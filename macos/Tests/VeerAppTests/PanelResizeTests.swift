import SwiftUI
import Testing
@testable import VeerApp

@MainActor struct PanelResizeTests {
    @Test func theGridCountsColumnsAsAnAdaptiveOneWould() {
        // Inside 24 pt margins, tiles at least 180 wide, 8 apart.
        #expect(GroupSection.columnCount(pageWidth: 880) == 4)
        #expect(GroupSection.columnCount(pageWidth: 499) == 2)
        #expect(GroupSection.columnCount(pageWidth: 416) == 2)
        #expect(GroupSection.columnCount(pageWidth: 415) == 1)
        #expect(GroupSection.columnCount(pageWidth: 0) == 1)
    }
}
