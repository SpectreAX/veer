import SwiftUI
import Testing
@testable import VeerApp

struct NodeMapLayoutTests {
    @Test func mapAndLegendUseTheMapCardsInsideWidth() {
        // The page less 24 pt margins and 16 pt card padding on each side.
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 680) == 600)
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 340) == 260)
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 50) == 0)
    }
}
