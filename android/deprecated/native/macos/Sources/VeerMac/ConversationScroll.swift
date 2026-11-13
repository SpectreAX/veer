import SwiftUI

/// Layout growth must not be confused with the user choosing to read history.
struct ConversationScrollState {
    private(set) var following = true
    private(set) var atBottom = true
    private(set) var userScrolling = false
    mutating func beginInteraction() { userScrolling = true; following = false }
    mutating func observeBottom(_ value: Bool) {
        atBottom = value
        if userScrolling { following = value }
    }
    mutating func endInteraction(atBottom value: Bool) {
        observeBottom(value); userScrolling = false
    }
    mutating func resume() { following = true; userScrolling = false }
}

struct ConversationScrollTracking: ViewModifier {
    @Binding var state: ConversationScrollState
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            let tolerance = WorkbenchStyle.scrollBottomTolerance
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
                } action: { _, bottom in state.observeBottom(bottom) }
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting { state.beginInteraction() }
                    else if phase == .idle && state.userScrolling {
                        state.endInteraction(atBottom: context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - tolerance)
                    }
                }
        } else { content }
    }
}
