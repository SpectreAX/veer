import AppKit
import Observation
import SwiftUI
import Testing
@testable import VeerApp
import VeerUI

/// The Agent panel stays built beneath the page when closed. Its composer is an AppKit text view,
/// which SwiftUI's `disabled` does not reach, so it must not hold or take the keyboard there.
@MainActor @Suite(.serialized) struct PanelComposerFocusTests {
    @Observable final class State {
        var presented = false
        var focusToken = 0
        var text = ""
    }

    @Test func aClosedKeptPanelDoesNotTakeTheKeyboardWhenBuilt() async throws {
        let state = State()
        let (window, hosting) = host(Stack(state: state))
        try await settle()
        let composer = try #require(textView(in: hosting))
        #expect(window.firstResponder !== composer)
        // Nor by Tab or any other direct request. (The window then takes it, and says yes.)
        window.makeFirstResponder(composer)
        #expect(window.firstResponder !== composer)
        // A focus request while it is closed waits for it to open.
        state.focusToken += 1
        try await settle()
        #expect(window.firstResponder !== composer)
        state.presented = true
        try await settle(1)
        #expect(window.firstResponder === composer)
    }

    @Test func closingThePanelGivesUpTheKeyboard() async throws {
        let state = State()
        state.presented = true
        let (window, hosting) = host(Stack(state: state))
        try await settle()
        let composer = try #require(textView(in: hosting))
        #expect(window.firstResponder === composer)
        state.presented = false
        // From the start of the motion, not only at its end.
        try await settle(0.05)
        #expect(window.firstResponder !== composer)
        try await settle(1)
        #expect(window.firstResponder !== composer)
    }

    @Test func theSmallestWindowNarrowsTheWidestPanelSoThePageFits() {
        // 860 wide beside a 200 pt sidebar: 380 left for the panel's column, which is the container
        // and the margin on either side of it; never below 320.
        #expect(AgentPanelColumn.fittedWidth(saved: 520, room: 660) == 380 - AgentPanelColumn.chrome)
        #expect(AgentPanelColumn.chrome == 16)
        #expect(AgentPanelColumn.fittedWidth(saved: 520, room: 600) == 320)
        #expect(AgentPanelColumn.fittedWidth(saved: 320, room: 600) == 320)
        // With room, the saved width; an invalid one is the ideal.
        #expect(AgentPanelColumn.fittedWidth(saved: 520, room: AgentPanelColumn.widestRoom) == 520)
        #expect(AgentPanelColumn.fittedWidth(saved: 0, room: .infinity) == 380)
        for room in stride(from: 600.0, through: 1200, by: 20) {
            let panel = AgentPanelColumn.fittedWidth(saved: 520, room: room)
            #expect(room - panel - AgentPanelColumn.chrome >= AgentPanelColumn.minimumPageWidth || panel == 320)
        }
    }

    @Observable final class Sized {
        var text: String
        var height: CGFloat = 0
        var width: CGFloat
        init(text: String, width: CGFloat) {
            self.text = text
            self.width = width
        }
    }

    @Test func aDraftPutInBeforeTheFieldHasItsWidthIsMeasuredOnceItDoes() async throws {
        // Two lines at the panel's width: an example or "Ask AI" fills the field as it is built.
        let sized = Sized(text: String(repeating: "mini4k.net 打不开，检查一下规则。", count: 3), width: 300)
        let (_, hosting) = host(Field(sized: sized))
        try await settle(0.3)
        hosting.layoutSubtreeIfNeeded()
        let line = try #require(textView(in: hosting)?.font?.boundingRectForFont.height).rounded(.up)
        #expect(sized.height > line * 1.5)
        // Narrower, the same text takes more lines.
        let before = sized.height
        sized.width = 160
        try await settle(0.3)
        hosting.layoutSubtreeIfNeeded()
        try await settle(0.3)
        #expect(sized.height > before)
    }

    private struct Field: View {
        let sized: Sized

        var body: some View {
            @Bindable var sized = sized
            ComposerTextView(text: $sized.text, composing: .constant(false), height: $sized.height, query: .constant(nil),
                             focusToken: 0, replaceRequest: .constant(nil), hasCompletions: false,
                             onMove: { _ in }, onPick: {}, onSubmit: {}, onPasteFiles: { _ in }, onPasteImage: { _ in })
                .frame(width: sized.width, height: max(sized.height, 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private struct Stack: View {
        let state: State

        var body: some View {
            @Bindable var state = state
            PanelRevealStack(isPresented: state.presented, panelWidth: 380, keepsPanelMounted: true) {
                Color.clear
            } panel: {
                ComposerTextView(text: $state.text, composing: .constant(false), height: .constant(20), query: .constant(nil),
                                 focusToken: state.focusToken, replaceRequest: .constant(nil), hasCompletions: false,
                                 onMove: { _ in }, onPick: {}, onSubmit: {}, onPasteFiles: { _ in }, onPasteImage: { _ in })
                    .frame(height: 20)
            }
        }
    }

    private func host(_ view: some View) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? ComposerNSTextView { return text }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    private func settle(_ duration: TimeInterval = 0.1) async throws {
        try await Task.sleep(for: .milliseconds(20))
        pump(for: duration)
        // Main-queue work, such as a focus request, runs only once this test yields.
        try await Task.sleep(for: .milliseconds(20))
    }

    private func pump(for duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}
