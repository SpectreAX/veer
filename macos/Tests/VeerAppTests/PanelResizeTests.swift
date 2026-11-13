import SwiftUI
import Testing
@testable import VeerApp

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

    @Test func theGridCountsColumnsAsAnAdaptiveOneWould() {
        // Inside 24 pt margins, tiles at least 180 wide, 8 apart.
        #expect(GroupSection.columnCount(pageWidth: 880) == 4)
        #expect(GroupSection.columnCount(pageWidth: 499) == 2)
        #expect(GroupSection.columnCount(pageWidth: 416) == 2)
        #expect(GroupSection.columnCount(pageWidth: 415) == 1)
        #expect(GroupSection.columnCount(pageWidth: 0) == 1)
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
}

private struct FrameProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 40)
    }
}
