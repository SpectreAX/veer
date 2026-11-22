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

    /// Only a search that matches nothing replaces the map with the way back; no search, or blank
    /// space, keeps the map even with no nodes to place.
    @MainActor @Test func onlyASearchThatFindsNothingReplacesTheMap() {
        let store = SnapshotRunner.running(page: .proxies)
        #expect(NodeMapView.searchFoundNothing(NodeMapView.regions(in: store, matching: "Relay K9"), query: "Relay K9"))
        #expect(!NodeMapView.searchFoundNothing(NodeMapView.regions(in: store, matching: "香港"), query: "香港"))
        #expect(!NodeMapView.searchFoundNothing([:], query: ""))
        #expect(!NodeMapView.searchFoundNothing([:], query: "  "))
    }

    @MainActor @Test func aSingleSearchRegionShowsItsMatchingNodesEvenWhenTheCurrentNodeIsElsewhere() {
        let store = SnapshotRunner.running(page: .proxies)
        let regions = NodeMapView.regions(in: store, matching: "香港")
        let current = store.mainGroup?.now.flatMap(store.region(of:))
        #expect(current == "JP")
        #expect(NodeMapView.selection(chosen: "US", current: current, in: regions, filtering: true) == "HK")
        #expect(regions["HK"]?.map(\.name) == ["🇭🇰 香港 01"])
    }

    @MainActor @Test func aSearchMatchingOnlyUnrecognizedNodesOpensThatRegion() {
        let node = MapNode(name: "Relay Alpha", delay: 20)
        let regions: [String?: [MapNode]] = [nil: [node]]
        #expect(NodeMapView.selection(chosen: nil, current: nil, in: regions, filtering: false) == nil)
        #expect(NodeMapView.selection(chosen: nil, current: nil, in: regions, filtering: true) == NodeMapView.unknownRegion)
    }

    @MainActor @Test func aRegionSummaryUsesMeasuredValuesAndDoesNotCallAllFailuresTimeouts() {
        let failed = [MapNode(name: "DNS failure", delay: 0, state: .failed("DNS")), MapNode(name: "not tested", delay: nil)]
        #expect(MapNode.bestDelay(in: failed) == nil)
        let measured = [MapNode(name: "Tokyo", delay: 92), MapNode(name: "Osaka", delay: 412)]
        #expect(MapNode.bestDelay(in: failed + measured) == 92)
    }

    @Test func aShortLabelSitsByARegionAtTheMapsEdge() {
        let map = CGSize(width: 328, height: 300)
        // Hong Kong near the right edge with a short label: held in by its own half width (60 + 4),
        // not by the 150 pt a 300 pt label would need.
        let short = MapCalloutLayout.center(for: CGPoint(x: 300, y: 150), label: CGSize(width: 120, height: 30), in: map)
        #expect(short.x == CGFloat(264))
        #expect(short.y == 150 - MapCalloutLayout.offset)
        // A wide label is still kept inside the map.
        let wide = MapCalloutLayout.center(for: CGPoint(x: 300, y: 150), label: CGSize(width: 300, height: 30), in: map)
        #expect(wide.x == CGFloat(174))
        // Room to spare: over the point itself.
        #expect(MapCalloutLayout.center(for: CGPoint(x: 160, y: 150), label: CGSize(width: 120, height: 30), in: map).x == 160)
        // Near the left edge, and below a region at the top.
        let left = MapCalloutLayout.center(for: CGPoint(x: 10, y: 20), label: CGSize(width: 120, height: 30), in: map)
        #expect(left == CGPoint(x: 64, y: 20 + MapCalloutLayout.offset))
        // A label wider than the map is centered rather than pushed off one side.
        #expect(MapCalloutLayout.center(for: CGPoint(x: 300, y: 150), label: CGSize(width: 400, height: 30), in: map).x == 164)
    }

    /// Found in the dark narrow map: a region near the bottom edge had its label below it, cut off.
    @Test func theLabelStaysInsideTheMapTopToBottom() {
        let small = CGSize(width: 200, height: 78), label = CGSize(width: 76, height: 22)
        let center = MapCalloutLayout.center(for: CGPoint(x: 100, y: 40), label: label, in: small)
        #expect(center.y + label.height / 2 <= small.height - MapCalloutLayout.inset)
        #expect(center.y - label.height / 2 >= MapCalloutLayout.inset)
        // A map too short for the label keeps the label where it was, rather than squeezing it.
        let tiny = MapCalloutLayout.center(for: CGPoint(x: 100, y: 10), label: label, in: CGSize(width: 200, height: 20))
        #expect(tiny.y == 10 + MapCalloutLayout.offset)
    }

    /// The card and the map read a region the same way, without the flag VoiceOver would read as a name.
    @MainActor @Test func aRegionReadsAsItsNameCountAndBestDelay() {
        let nodes = [MapNode(name: "Tokyo", delay: 92), MapNode(name: "Osaka", delay: 412)]
        let summary = NodeMapView.regionSummary("JP", nodes: nodes)
        #expect(!summary.contains("🇯🇵"))
        #expect(summary.contains("2") && summary.contains(Format.delay(92)))
        #expect(NodeMapView.regionSummary(NodeMapView.unknownRegion, nodes: nodes).contains("2"))
        // No measurement: a word, not the dash the page shows.
        let untested = NodeMapView.regionSummary("SG", nodes: [MapNode(name: "Singapore", delay: nil)])
        #expect(!untested.contains("—") && untested.contains(String(localized: "未测速")))
    }

    /// Found in the live map at 860 × 560 with the Agent docked: dragged near the top trailing corner,
    /// Japan's label sat under Show Whole Map. It now keeps clear of the button.
    @Test func theLabelKeepsClearOfShowWholeMap() {
        let label = CGSize(width: 76, height: 22)
        func frame(_ center: CGPoint) -> CGRect {
            CGRect(x: center.x - label.width / 2, y: center.y - label.height / 2, width: label.width, height: label.height)
        }
        // The live case: a 200 × 78 map, the region 4 pt from the top near the trailing edge.
        let small = CGSize(width: 200, height: 78), button = MapCalloutLayout.buttonArea(in: small)
        let placed = MapCalloutLayout.center(for: CGPoint(x: 185, y: 4), label: label, in: small, avoiding: button)
        #expect(!frame(placed).intersects(button))
        #expect(frame(placed).minX >= 0 && frame(placed).maxY <= small.height)
        // Below the button, still over the region, and not over Hong Kong's mark at (100, 40).
        #expect(placed.x == 158)
        #expect(!frame(placed).contains(CGPoint(x: 100, y: 40)))
        // Room on the other side of the region: it moves there instead.
        let tall = CGSize(width: 400, height: 300), corner = MapCalloutLayout.buttonArea(in: tall)
        let flipped = MapCalloutLayout.center(for: CGPoint(x: 380, y: 60), label: label, in: tall, avoiding: corner)
        #expect(!frame(flipped).intersects(corner))
        #expect(flipped.y == 60 + MapCalloutLayout.offset)
        // Nothing to avoid, or not in the way: placed as before.
        #expect(MapCalloutLayout.center(for: CGPoint(x: 185, y: 4), label: label, in: small)
            == MapCalloutLayout.center(for: CGPoint(x: 185, y: 4), label: label, in: small, avoiding: nil))
        #expect(MapCalloutLayout.center(for: CGPoint(x: 100, y: 150), label: label, in: tall, avoiding: corner)
            == CGPoint(x: 100, y: 150 - MapCalloutLayout.offset))
    }
}
