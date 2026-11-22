import AppKit
import Observation
import SwiftUI
import Testing
@testable import VeerUI

@MainActor @Suite(.serialized) struct SteadyGridTests {
    @Observable final class Positions { var minX: [Int: CGFloat] = [:] }
    @Observable final class Shown {
        var motion: PanelMotion?
        var row = false
        var stack = false
    }

    @Test func countsColumnsAsAdaptiveGridItemsDo() {
        #expect(SteadyGrid<EmptyView>.columns(width: 180, minimum: 180, spacing: 8) == 1)
        #expect(SteadyGrid<EmptyView>.columns(width: 367, minimum: 180, spacing: 8) == 1)
        #expect(SteadyGrid<EmptyView>.columns(width: 368, minimum: 180, spacing: 8) == 2)
        #expect(SteadyGrid<EmptyView>.columns(width: 0, minimum: 180, spacing: 8) == 1)
        #expect(SteadyGrid<EmptyView>.columns(width: .infinity, minimum: 180, spacing: 8) == 1)
    }

    @Test func holdsTheNarrowerEndsCountInEitherDirection() {
        let opening = PanelMotion(id: 1, widthChange: -380)
        let closing = PanelMotion(id: 2, widthChange: 380)
        // From 940 wide to 560: what fits at the end.
        #expect(SteadyGrid<EmptyView>.heldColumns(width: 940, motion: opening, minimum: 180, spacing: 8) == 3)
        // From 560 to 940: the count it starts with.
        #expect(SteadyGrid<EmptyView>.heldColumns(width: 560, motion: closing, minimum: 180, spacing: 8) == 3)
        // Five fit at 940 itself.
        #expect(SteadyGrid<EmptyView>.columns(width: 940, minimum: 180, spacing: 8) == 5)
    }

    @Test func aChoiceHoldsWhatFitsAtTheNarrowerEnd() {
        typealias Choice = SteadyChoice<EmptyView, EmptyView>
        // 656 wide needs 656: a row while closing from there, stacked from the start of an opening.
        #expect(Choice.heldFits(width: 656, motion: PanelMotion(id: 1, widthChange: 380), requiredWidth: 656))
        #expect(!Choice.heldFits(width: 1035, motion: PanelMotion(id: 2, widthChange: -380), requiredWidth: 656))
        #expect(Choice.heldFits(width: 1036, motion: PanelMotion(id: 3, widthChange: -380), requiredWidth: 656 - 380))
    }

    @Test func aChoiceShowsTheRowOnlyWhenItFits() async throws {
        for (width, expectsRow) in [(700.0, true), (655, false)] {
            let positions = Positions()
            let view = SteadyChoice(requiredWidth: 656) {
                Color.clear.frame(width: 656, height: 10).onAppear { positions.minX[0] = 1 }
            } narrow: {
                Color.clear.frame(height: 10).onAppear { positions.minX[1] = 1 }
            }
            .frame(width: width)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            pump(for: 0.05)
            #expect((positions.minX[0] != nil) == expectsRow, "at \(width)")
            #expect((positions.minX[1] != nil) == !expectsRow, "at \(width)")
            _ = window
        }
    }

    @Test func aChoiceHoldsThroughAMotionAndDecidesAgainAtRest() async throws {
        let shown = Shown()
        let view = ChoiceHost(shown: shown)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(shown.row && !shown.stack)
        // Opening a 380 panel from 700: the row would not fit at the end, so it is stacked from the start.
        shown.motion = PanelMotion(id: 1, widthChange: -380)
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(!shown.row && shown.stack)
        shown.motion = nil
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(shown.row && !shown.stack)
        _ = window
    }

    /// A reversal part way is a new motion (a new id) between the same two ends: the choice made at
    /// the start holds. Worked out again from the middle, it took the far end one panel further and
    /// changed twice (design review, 2026-11-20).
    @Test func aChoiceHoldsThroughAReversal() async throws {
        let shown = Shown()
        let hosting = NSHostingView(rootView: ChoiceHost(shown: shown))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        // Closing a 380 panel from 700: the row fits at both ends.
        shown.motion = PanelMotion(id: 1, widthChange: 380)
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(shown.row && !shown.stack)
        // Turned back: from this width the far end would now be 320, but it is the same motion's start.
        shown.motion = PanelMotion(id: 2, widthChange: -380)
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(shown.row && !shown.stack)
        _ = window
    }

    private struct ChoiceHost: View {
        let shown: Shown

        var body: some View {
            SteadyChoice(requiredWidth: 656) {
                Color.clear.frame(width: 656, height: 10).onAppear { shown.row = true }.onDisappear { shown.row = false }
            } narrow: {
                Color.clear.frame(height: 10).onAppear { shown.stack = true }.onDisappear { shown.stack = false }
            }
            .environment(\.panelMotion, shown.motion)
        }
    }

    /// A header going between two lines and one: the ends are the two forms, the detail never runs
    /// under the actions, and its height changes without a jump.
    @Test func aHeaderGoesBetweenTwoLinesAndOneContinuously() {
        let parts = BlendedHeaderLayout.Parts(title: CGSize(width: 120, height: 20), badge: CGSize(width: 70, height: 18),
                                              detail: CGSize(width: 260, height: 18), actions: CGSize(width: 150, height: 24))
        let needed = BlendedHeaderLayout.oneLineWidth(parts, spacing: 8)
        #expect(needed == CGFloat(624))
        let range: ClosedRange<CGFloat> = 420...800
        var previousHeight: CGFloat?
        for step in 0...190 {
            let width = range.lowerBound + CGFloat(step) * 2
            let frames = BlendedHeaderLayout.frames(parts, width: width, spacing: 8, rowSpacing: 4, motionWidths: range)
            #expect(frames[2].maxX <= frames[3].minX + 0.5 || frames[2].minY >= frames[3].maxY - 0.5, "detail under actions at \(width)")
            #expect(frames[0].maxX <= frames[3].minX + 0.5)
            let height = frames.map(\.maxY).max() ?? 0
            if let previousHeight { #expect(abs(height - previousHeight) < 3, "height jumps at \(width)") }
            previousHeight = height
        }
        let narrow = BlendedHeaderLayout.frames(parts, width: 420, spacing: 8, rowSpacing: 4, motionWidths: range)
        #expect(narrow[1].minY > narrow[0].minY && narrow[1].minX == 0)
        let wide = BlendedHeaderLayout.frames(parts, width: 800, spacing: 8, rowSpacing: 4, motionWidths: range)
        #expect(Set(wide.map(\.minY)).count == 1)
        // At rest the width alone decides.
        #expect(BlendedHeaderLayout.frames(parts, width: 800, spacing: 8, rowSpacing: 4, motionWidths: nil) == wide)
        #expect(BlendedHeaderLayout.frames(parts, width: 420, spacing: 8, rowSpacing: 4, motionWidths: nil) == narrow)
    }

    @Test func aBlendedGridMovesEachItemContinuouslyFromOneColumnToMore() {
        let range: ClosedRange<CGFloat> = 300...780
        var previous: [CGRect]?
        for step in 0...240 {
            let width = range.lowerBound + CGFloat(step) * 2
            func items(_ columns: Int) -> [ArrangedItem] {
                BlendedGridLayout.items(count: 7, columns: columns, width: width, spacing: 8).map {
                    ArrangedItem(x: $0.x, width: $0.width, row: $0.row, height: 44)
                }
            }
            let frames = ArrangementBlend.frames(narrow: items(1), wide: items(3), spacing: 8,
                                                 progress: ArrangementBlend.progress(width: width, range: range))
            for first in frames.indices {
                for second in frames.indices where second > first {
                    #expect(!frames[first].insetBy(dx: 0.5, dy: 0.5).intersects(frames[second].insetBy(dx: 0.5, dy: 0.5)), "at \(width)")
                }
            }
            if let previous {
                for (now, before) in zip(frames, previous) { #expect(abs(now.minX - before.minX) < 12 && abs(now.minY - before.minY) < 12) }
            }
            previous = frames
        }
        #expect(BlendedGridLayout.columns(width: 300, minimum: 240, spacing: 8) == 1)
        #expect(BlendedGridLayout.columns(width: 780, minimum: 240, spacing: 8) == 3)
    }

    /// The count it computes is the one `LazyVGrid` lays out, so holding it changes nothing at rest.
    @Test func matchesTheGridItLaysOut() async throws {
        for width in [300.0, 380, 560, 760, 940] {
            let positions = Positions()
            let view = SteadyGrid(minimum: 180, spacing: 8) {
                ForEach(0..<12, id: \.self) { index in
                    Color.clear.frame(height: 20)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { positions.minX[index] = $0 }
                }
            }
            .frame(width: width)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            pump(for: 0.05)
            let columns = Set(positions.minX.values.map { Int($0.rounded()) }).count
            #expect(columns == SteadyGrid<EmptyView>.columns(width: width, minimum: 180, spacing: 8), "at \(width)")
            _ = window
        }
    }

    private func pump(for duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}
