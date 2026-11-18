import SwiftUI
import Testing
@testable import VeerApp
import VeerUI

@MainActor struct PanelResizeTests {
    @Test func overviewPlacesCardsInsideTheirWidthWithoutOverlap() throws {
        for hasTraffic in [false, true] {
            for pageWidth in [459.0, 460, 719, 720, 800] {
                let probes = (0..<(hasTraffic ? 3 : 2)).map { _ in NSView() }
                let host = NSHostingView(rootView: OverviewCardsLayout(hasTraffic: hasTraffic) {
                    ForEach(probes.indices, id: \.self) { index in
                        FrameProbe(view: probes[index])
                    }
                }.frame(width: pageWidth - 48))
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let frames = try probes.map { view in
                    _ = try #require(view.superview)
                    return host.convert(view.bounds, from: view)
                }
                for frame in frames {
                    #expect(frame.minX >= -0.001)
                    #expect(frame.maxX <= pageWidth - 48 + 0.001)
                    #expect(frame.minY >= -0.001)
                    #expect(frame.maxY <= host.bounds.height + 0.001)
                    #expect(abs(frame.height - 40) < 0.001)
                }
                for first in frames.indices {
                    for second in frames.indices where second > first {
                        #expect(!frames[first].insetBy(dx: 0.001, dy: 0.001).intersects(frames[second]))
                    }
                }
                let rows = Set(frames.map { Int($0.midY.rounded()) }).count
                #expect(rows == (pageWidth >= 720 ? 1 : hasTraffic && pageWidth < 460 ? 3 : 2))
            }
        }
    }

    @Test func overviewMeasuresTheNewArrangementInTheSamePass() {
        func cards(pageWidth: CGFloat, height: CGFloat = 40) -> some View {
            OverviewCardsLayout(hasTraffic: true) {
                Color.clear.frame(height: height)
                Color.clear.frame(height: height)
                Color.clear.frame(height: height)
            }
            .frame(width: pageWidth - 48)
        }
        let host = NSHostingView(rootView: cards(pageWidth: 800))
        // Reuse one hosting hierarchy across both breakpoints and reversals. No geometry
        // callback or subsequent run-loop pass may be needed to get the right height.
        for (width, height) in [(720.0, 40.0), (719, 96), (460, 96), (459, 152), (460, 96), (720, 40)] {
            host.rootView = cards(pageWidth: width)
            #expect(abs(host.fittingSize.height - height) < 0.001)
            #expect(abs(host.fittingSize.width - (width - 48)) < 0.001)
        }
        // The same width must also accommodate changed child content.
        host.rootView = cards(pageWidth: 720, height: 80)
        #expect(abs(host.fittingSize.height - 80) < 0.001)
    }

    @Test func overviewChangesArrangementOnlyAtActualWidthBreakpoints() {
        #expect(OverviewArrangement(width: 0) == .stackedPairs)
        #expect(OverviewArrangement(width: 459) == .stackedPairs)
        #expect(OverviewArrangement(width: 460) == .stackedRows)
        #expect(OverviewArrangement(width: 461) == .stackedRows)
        #expect(OverviewArrangement(width: 719) == .stackedRows)
        #expect(OverviewArrangement(width: 720) == .columns)
        #expect(OverviewArrangement(width: 721) == .columns)
        for width in stride(from: 500.0, through: 700.0, by: 10) {
            let arrangement = OverviewArrangement(width: width)
            #expect(arrangement.stacksRows)
            #expect(!arrangement.stacksPairs)
        }
        for width in stride(from: 800.0, through: 1080.0, by: 10) {
            #expect(OverviewArrangement(width: width) == .columns)
        }
    }

    @Test func overviewKnowsItsLayoutWidthsAtBothEndsOfAMotion() {
        // Opening a 381 panel beside an 860 page: the cards' layout goes from 812 to 431.
        #expect(OverviewView.motionWidths(pageWidth: 860, motion: PanelMotion(id: 1, widthChange: -381)) == 431...812)
        #expect(OverviewView.motionWidths(pageWidth: 479, motion: PanelMotion(id: 2, widthChange: 381)) == 431...812)
        // Wider than the content at both ends: one width, so nothing to blend.
        let capped = OverviewView.motionWidths(pageWidth: 1700, motion: PanelMotion(id: 3, widthChange: -381))
        #expect(capped.lowerBound == capped.upperBound)
    }

    /// Between any two arrangements, at every width on the way: the ends are the arrangements
    /// themselves, no two cards overlap, and every card moves and resizes continuously.
    @Test func overviewCardsGoFromOneArrangementToAnotherWithoutJumpsOrOverlap() {
        struct Case {
            let narrow: OverviewArrangement
            let wide: OverviewArrangement
            let range: ClosedRange<CGFloat>
        }
        let cases = [Case(narrow: .stackedPairs, wide: .stackedRows, range: 380...620),
                     Case(narrow: .stackedRows, wide: .columns, range: 600...900),
                     Case(narrow: .stackedPairs, wide: .columns, range: 380...900)]
        for hasTraffic in [true, false] {
            for item in cases {
                let narrow = item.narrow, wide = item.wide, range = item.range
                var previous: [CGRect]?
                for step in 0...200 {
                    let width = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(step) / 200
                    func items(_ arrangement: OverviewArrangement) -> [ArrangedItem] {
                        // Cards 90 pt tall, taller when narrow, as wrapped text makes them.
                        var items = OverviewCardsLayout.columns(arrangement, hasTraffic: hasTraffic, width: width)
                        for index in items.indices { items[index].height = items[index].width < 250 ? 120 : 90 }
                        for index in items.indices {
                            items[index].height = items.filter { $0.row == items[index].row }.map(\.height).max() ?? 0
                        }
                        return items
                    }
                    let frames = ArrangementBlend.frames(narrow: items(narrow), wide: items(wide), spacing: Spacing.lg,
                                                         progress: ArrangementBlend.progress(width: width, range: range))
                    for first in frames.indices {
                        for second in frames.indices where second > first {
                            #expect(!frames[first].insetBy(dx: 0.5, dy: 0.5).intersects(frames[second].insetBy(dx: 0.5, dy: 0.5)),
                                    "\(narrow)→\(wide) at \(width): \(first) over \(second)")
                        }
                    }
                    if let previous {
                        for (now, before) in zip(frames, previous) {
                            // A 200th of the way: nothing may move by more than a few points, bar the
                            // one step where a narrow card's taller text changes its row's height.
                            #expect(abs(now.minX - before.minX) < 8 && abs(now.width - before.width) < 8 && abs(now.minY - before.minY) < 40,
                                    "\(narrow)→\(wide) at \(width)")
                        }
                    }
                    previous = frames
                }
                let start = ArrangementBlend.frames(narrow: OverviewCardsLayout.columns(narrow, hasTraffic: hasTraffic, width: range.lowerBound),
                                                    wide: OverviewCardsLayout.columns(wide, hasTraffic: hasTraffic, width: range.lowerBound),
                                                    spacing: Spacing.lg, progress: 0)
                #expect(start.map(\.minX) == OverviewCardsLayout.columns(narrow, hasTraffic: hasTraffic, width: range.lowerBound).map(\.x))
                let end = ArrangementBlend.frames(narrow: OverviewCardsLayout.columns(narrow, hasTraffic: hasTraffic, width: range.upperBound),
                                                  wide: OverviewCardsLayout.columns(wide, hasTraffic: hasTraffic, width: range.upperBound),
                                                  spacing: Spacing.lg, progress: 1)
                #expect(end.map(\.minX) == OverviewCardsLayout.columns(wide, hasTraffic: hasTraffic, width: range.upperBound).map(\.x))
            }
        }
    }

    @Test func theContentSeesOnlyTheChangeBelowItsWidestWidth() {
        let cap = OverviewView.maxContentWidth
        #expect(OverviewView.contentMotion(pageWidth: 860, motion: PanelMotion(id: 1, widthChange: -381)).widthChange == -381)
        #expect(OverviewView.contentMotion(pageWidth: cap + 500, motion: PanelMotion(id: 2, widthChange: -381)).widthChange == 0)
        #expect(OverviewView.contentMotion(pageWidth: cap + 100, motion: PanelMotion(id: 3, widthChange: -381)).widthChange == -281)
        #expect(OverviewView.contentMotion(pageWidth: cap - 281, motion: PanelMotion(id: 4, widthChange: 381)).widthChange == 281)
    }
}

private struct FrameProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 40)
    }
}
