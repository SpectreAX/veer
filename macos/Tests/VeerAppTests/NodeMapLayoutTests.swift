import SwiftUI
import Testing
@testable import VeerApp

struct NodeMapLayoutTests {
    @Test func regionColumnsFitCardsInsideThePageMargins() {
        // 24 pt margins, cards at least 220 wide and 8 apart: n cards need 228n - 8 + 48.
        #expect(NodeMapLayout.regionColumns(pageWidth: 0) == 1)
        #expect(NodeMapLayout.regionColumns(pageWidth: 495) == 1)
        #expect(NodeMapLayout.regionColumns(pageWidth: 496) == 2)
        #expect(NodeMapLayout.regionColumns(pageWidth: 723) == 2)
        #expect(NodeMapLayout.regionColumns(pageWidth: 724) == 3)
        #expect(NodeMapLayout.regionColumns(pageWidth: 1080) == 4)
    }

    @Test func mapAndLegendUseTheMapCardsInsideWidth() {
        // The page less 24 pt margins and 16 pt card padding on each side.
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 680) == 600)
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 340) == 260)
        #expect(NodeMapLayout.cardInsideWidth(pageWidth: 50) == 0)
    }

    @Test func mapPictureIsDrawnAtTheWidthThePanelStopsAt() {
        // Every width on the way gives the same picture: drawn once per motion.
        let widths = Set(stride(from: 560.0, through: 1032, by: 0.5).map {
            NodeMapLayout.pictureWidth(mapWidth: $0, targetMapWidth: 600)
        })
        #expect(widths == [600])
        #expect(NodeMapLayout.pictureWidth(mapWidth: 812.4, targetMapWidth: nil) == 813)
        #expect(NodeMapLayout.pictureWidth(mapWidth: 0, targetMapWidth: 0) == 1)
    }
}
