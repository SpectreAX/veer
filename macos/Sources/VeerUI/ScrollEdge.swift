import SwiftUI

/// Bars over scrolling content, and the system's soft edge where content meets them. From macOS 26
/// a bar the system knows about lets the content scroll on under it, blurred and faded by the
/// system; before macOS 26 there is no such effect, and content stops at the bar.
public enum ScrollEdge {
    /// Whether this system draws bars over scrolling content with an edge effect: macOS 26 and
    /// later. Layouts that place things differently around such a bar decide on this.
    nonisolated public static let available: Bool = { if #available(macOS 26, *) { true } else { false } }()
}

public extension View {
    /// The system's soft edge where this view's scroll views meet a bar at `edges`: macOS 26's own
    /// blur and fade, never one drawn by hand. Before macOS 26 the view is left as it is.
    @ViewBuilder func softScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// `bar` at `edge` as a bar the system knows about (`safeAreaBar`), so scroll views under it get
    /// its edge effect. Before macOS 26, an ordinary inset; a layout that needs something else
    /// there checks `ScrollEdge.available` instead.
    @ViewBuilder func scrollEdgeBar(edge: VerticalEdge, spacing: CGFloat? = nil, @ViewBuilder content bar: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: bar)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: bar)
        }
    }
}
