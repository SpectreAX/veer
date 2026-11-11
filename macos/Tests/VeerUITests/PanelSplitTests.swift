import AppKit
import Observation
import SwiftUI
import Testing
@testable import VeerUI

@MainActor @Suite(.serialized) struct PanelSplitTests {
    @Observable final class Measurement {
        var presented = false
        var widths: [CGFloat] = []
    }

    @Test func theSwiftUIPageReceivesIntermediateProposalsBeforeTheNativeAnimationEnds() async throws {
        let measurement = Measurement()
        let root = MeasuringSplit(measurement: measurement)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.03)
        measurement.widths = []
        measurement.presented = true
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.15)
        #expect(measurement.widths.contains { $0 > 700 && $0 < 1070 })
        _ = window.contentView
    }

    private struct MeasuringSplit: View {
        let measurement: Measurement

        var body: some View {
            PanelSplitView(isPresented: measurement.presented, width: .constant(380)) {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.widths.append($0) }
            } panel: {
                Color.clear
            }
        }
    }

    @Test func swiftUIColumnsReceiveDisjointRealBoundsWithoutReplacingTheirHostingTree() async throws {
        let view = NSHostingView(rootView: PanelSplitView(isPresented: true, width: .constant(380)) {
            Color.clear
        } panel: {
            Color.clear.frame(width: 380)
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        let split = try #require(findSplit(in: view))
        #expect(split.arrangedSubviews.count == 2)
        #expect(abs(split.arrangedSubviews[1].frame.width - 380) < 1)
        #expect(split.arrangedSubviews[0].frame.maxX <= split.arrangedSubviews[1].frame.minX)
        window.setContentSize(CGSize(width: 860, height: 560))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(abs(split.arrangedSubviews[1].frame.width - 380) < 1)
        #expect(window.contentView === view)
    }

    private func findSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { findSplit(in: $0) }.first
    }

    @Test func olderInvalidPanelWidthsUseTheOriginalDefault() {
        for width in [0.0, 700, -.infinity, .infinity, .nan] {
            #expect(PanelSplitMetrics.width(width) == 380)
        }
        #expect(PanelSplitMetrics.width(320) == 320)
        #expect(PanelSplitMetrics.width(520) == 520)
    }

    @Test func reducedMotionKeepsBothColumnsInsideTheExistingWindow() async throws {
        let fixture = fixture()
        try await Task.sleep(for: .milliseconds(20))
        for shown in [true, false, true] {
            fixture.connector.configure(presented: shown, width: 380, animated: false) { _ in }
            #expect(abs(fixture.split.arrangedSubviews[1].frame.width - (shown ? 380 : 0)) < 1)
            #expect(fixture.window.frame.width == 1080)
            #expect(fixture.split.arrangedSubviews[0].frame.maxX <= fixture.split.arrangedSubviews[1].frame.minX)
        }
        fixture.connector.disconnect()
    }

    @Test func reversingAnAnimationStartsAtTheCurrentDividerAndDetachmentCancelsIt() async throws {
        let fixture = fixture()
        try await Task.sleep(for: .milliseconds(20))
        fixture.connector.configure(presented: true, width: 380, animated: true) { _ in }
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.07)
        let interruptedWidth = fixture.split.arrangedSubviews[1].frame.width
        #expect(interruptedWidth > 0 && interruptedWidth < 380)
        fixture.connector.configure(presented: false, width: 380, animated: true) { _ in }
        #expect(abs(fixture.split.arrangedSubviews[1].frame.width - interruptedWidth) < 1)
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.3)
        #expect(fixture.split.arrangedSubviews[1].frame.width < 1)
        fixture.connector.configure(presented: true, width: 380, animated: true) { _ in }
        fixture.connector.disconnect()
        let detachedWidth = fixture.split.arrangedSubviews[1].frame.width
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.3)
        #expect(fixture.split.arrangedSubviews[1].frame.width == detachedWidth)
        #expect(fixture.window.frame.width == 1080)
    }

    private func pump(for duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }

    private struct Fixture {
        let window: NSWindow
        let split: NSSplitView
        let connector: PanelDividerConnector
    }

    private func fixture() -> Fixture {
        let split = NSSplitView(frame: CGRect(x: 0, y: 0, width: 1080, height: 720))
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.adjustSubviews()
        let window = NSWindow(contentRect: split.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = split
        let connector = PanelDividerConnector()
        split.arrangedSubviews[1].addSubview(connector)
        connector.configure(presented: false, width: 380, animated: false) { _ in }
        return Fixture(window: window, split: split, connector: connector)
    }
}
