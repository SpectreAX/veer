import AppKit
import Observation
import SwiftUI
import Testing
@testable import VeerUI

@MainActor @Suite(.serialized) struct PanelRevealTests {
    @Observable final class Measurement {
        var presented = false
        var pageWidths: [CGFloat] = []
        var panelMinX: [CGFloat] = []
        var panelMounted = false
        var itemWidth: CGFloat = 80
        var contentItemWidths: [CGFloat] = []
        var panelItemWidths: [CGFloat] = []
        var contentAnimationReceived = false
        var panelAnimationReceived = false
    }

    @Test func thePageGetsEachRealWidthAndThePanelFollowsItsEdge() async throws {
        let measurement = Measurement()
        let window = host(MeasuringStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(measurement.pageWidths.last == 1080)
        measurement.pageWidths = []
        measurement.panelMinX = []
        measurement.presented = true
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.15)
        // Part way, before the spring settles.
        #expect(measurement.pageWidths.contains { $0 > 710 && $0 < 1070 })
        pump(for: 0.8)
        #expect(abs((measurement.pageWidths.last ?? 0) - 700) < 0.5)
        #expect(abs((measurement.panelMinX.last ?? 0) - 700) < 0.5)
        // Pushed in from past the trailing edge: it starts beyond the page's full width and only
        // moves toward its place, never back.
        #expect(measurement.panelMinX.contains { $0 > 710 && $0 < 1070 })
        #expect(zip(measurement.panelMinX, measurement.panelMinX.dropFirst()).allSatisfy { $1 <= $0 + 0.5 })
        _ = window
    }

    @Test func theWindowKeepsItsSize() async throws {
        let measurement = Measurement()
        let window = host(MeasuringStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        for shown in [true, false, true] {
            measurement.presented = shown
            try await Task.sleep(for: .milliseconds(10))
            pump(for: 0.8)
            #expect(window.frame.width == 1080)
            #expect(abs((measurement.pageWidths.last ?? 0) - (shown ? 700 : 1080)) < 0.5)
        }
    }

    @Test func reversingPartWayTurnsBackFromWhereThePageIs() async throws {
        let measurement = Measurement()
        let window = host(MeasuringStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        measurement.presented = true
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.08)
        let interrupted = try #require(measurement.pageWidths.last)
        #expect(interrupted < 1080 && interrupted > 700)
        measurement.presented = false
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.03)
        // No jump to either end: it carries on from about where it was.
        #expect(abs((measurement.pageWidths.last ?? 0) - interrupted) < 120)
        pump(for: 0.8)
        #expect(abs((measurement.pageWidths.last ?? 0) - 1080) < 0.5)
        _ = window
    }

    @Test func thePanelsLeadingEdgeIsThePagesTrailingEdgeAtEveryStep() {
        for reveal in stride(from: -0.05, through: 1.05, by: 0.05) {
            let page = PanelRevealLayout.pageWidth(total: 1080, panelWidth: 380, reveal: reveal)
            let panelMinX = 1080 - 380 + PanelPush.offset(panelWidth: 380, reveal: reveal)
            #expect(abs(panelMinX - page) < 0.001)
        }
        // Closed, the whole panel is past the edge; open, it is in its place.
        #expect(PanelPush.offset(panelWidth: 380, reveal: 0) == 380)
        #expect(PanelPush.offset(panelWidth: 380, reveal: 1) == 0)
    }

    @Test func layoutPlacesPageAndPanelWithoutOverlapAtEveryStep() {
        for reveal in stride(from: -0.05, through: 1.05, by: 0.05) {
            let page = PanelRevealLayout.pageWidth(total: 1080, panelWidth: 380, reveal: reveal)
            #expect(page >= 700 && page <= 1080)
        }
        #expect(PanelRevealLayout.pageWidth(total: 1080, panelWidth: 380, reveal: 0.5) == 890)
        #expect(PanelRevealLayout.pageWidth(total: 300, panelWidth: 380, reveal: 1) == 0)
    }

    @Test func olderInvalidPanelWidthsUseTheOriginalDefault() {
        for width in [0.0, 700, -.infinity, .infinity, .nan] {
            #expect(PanelSplitMetrics.width(width) == 380)
        }
        #expect(PanelSplitMetrics.width(320) == 320)
        #expect(PanelSplitMetrics.width(520) == 520)
    }

    @Test func pageChangesRemoveTheHiddenPanelWithoutWaitingForASpring() async throws {
        let measurement = Measurement()
        measurement.presented = true
        let window = host(MountingStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(measurement.panelMounted)
        measurement.presented = false
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(!measurement.panelMounted)
        _ = window
    }

    @Test func aKeptPanelIsBuiltWhileHiddenAndThePageKeepsItsWidth() async throws {
        let measurement = Measurement()
        let window = host(KeptStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        #expect(measurement.panelMounted)
        #expect(measurement.pageWidths.last == 1080)
        measurement.presented = true
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.8)
        measurement.presented = false
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.8)
        // Still there after closing: the next opening has nothing to build.
        #expect(measurement.panelMounted)
        #expect(abs((measurement.pageWidths.last ?? 0) - 1080) < 0.5)
        _ = window
    }

    @Test func reducedMotionDoesNotWaitForAnAnimatedTransition() {
        typealias Presentation = PanelRevealStack<EmptyView, EmptyView>.Presentation
        let before = Presentation(shown: true, trigger: true, reduceMotion: false)
        #expect(!Presentation(shown: false, trigger: false, reduceMotion: true).animates(from: before))
        #expect(Presentation(shown: false, trigger: false, reduceMotion: false).animates(from: before))
        #expect(!Presentation(shown: false, trigger: true, reduceMotion: false).animates(from: before))
    }

    /// Above the page while open or moving, so its glass shadow is not cut by the page; beneath it at
    /// rest when closed, so a panel kept mounted casts no shadow at the window's trailing edge.
    @Test func panelDrawsAbovePageOnlyWhileOpenOrMoving() {
        typealias Stack = PanelRevealStack<EmptyView, EmptyView>
        #expect(!Stack.panelAbovePage(interactive: false, moving: false))
        #expect(Stack.panelAbovePage(interactive: false, moving: true))
        #expect(Stack.panelAbovePage(interactive: true, moving: true))
        #expect(Stack.panelAbovePage(interactive: true, moving: false))
    }

    @Test func ordinaryAnimationTransactionsReachEitherColumn() async throws {
        let measurement = Measurement()
        measurement.presented = true
        let window = host(ContentMotionStack(measurement: measurement))
        try await Task.sleep(for: .milliseconds(20))
        pump(for: 0.05)
        measurement.contentItemWidths = []
        measurement.panelItemWidths = []
        withAnimation(.linear(duration: 0.25)) { measurement.itemWidth = 160 }
        try await Task.sleep(for: .milliseconds(10))
        pump(for: 0.15)
        #expect(measurement.contentAnimationReceived)
        #expect(measurement.panelAnimationReceived)
        pump(for: 0.25)
        #expect(abs((measurement.contentItemWidths.last ?? 0) - 160) < 0.5)
        #expect(abs((measurement.panelItemWidths.last ?? 0) - 160) < 0.5)
        _ = window
    }

    private struct ContentMotionStack: View {
        let measurement: Measurement

        var body: some View {
            PanelRevealStack(isPresented: measurement.presented, panelWidth: 380) {
                Color.clear.frame(width: measurement.itemWidth)
                    .transaction { if $0.animation == .linear(duration: 0.25) { measurement.contentAnimationReceived = true } }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.contentItemWidths.append($0) }
            } panel: {
                Color.clear.frame(width: measurement.itemWidth)
                    .transaction { if $0.animation == .linear(duration: 0.25) { measurement.panelAnimationReceived = true } }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.panelItemWidths.append($0) }
            }
        }
    }

    private struct MountingStack: View {
        let measurement: Measurement

        var body: some View {
            PanelRevealStack(isPresented: measurement.presented, panelWidth: 380, animationTrigger: false) {
                Color.clear
            } panel: {
                Color.clear.onAppear { measurement.panelMounted = true }.onDisappear { measurement.panelMounted = false }
            }
        }
    }

    private struct KeptStack: View {
        let measurement: Measurement

        var body: some View {
            PanelRevealStack(isPresented: measurement.presented, panelWidth: 380, keepsPanelMounted: true) {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.pageWidths.append($0) }
            } panel: {
                Color.clear.onAppear { measurement.panelMounted = true }.onDisappear { measurement.panelMounted = false }
            }
        }
    }

    private struct MeasuringStack: View {
        let measurement: Measurement

        var body: some View {
            PanelRevealStack(isPresented: measurement.presented, panelWidth: 380) {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measurement.pageWidths.append($0) }
            } panel: {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { measurement.panelMinX.append($0) }
            }
        }
    }

    private func host(_ view: some View) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    private func pump(for duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}
