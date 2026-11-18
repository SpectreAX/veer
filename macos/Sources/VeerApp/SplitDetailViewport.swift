import SwiftUI

/// NavigationSplitView can lay out its detail at the destination width while AppKit is still
/// moving the column. Keep the page's right edge inside the split at every intermediate position.
struct SplitDetailViewport<Content: View>: View {
    @Environment(\.panelContentTargetWidth) private var targetSplitWidth
    let splitWidth: CGFloat
    let coordinateSpace: Namespace.ID
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let width = SplitDetailLayout.visibleWidth(proposed: geometry.size.width, split: splitWidth,
                                                       leading: geometry.frame(in: .named(coordinateSpace)).minX)
            let target = targetSplitWidth.map { max(0, $0 - geometry.frame(in: .named(coordinateSpace)).minX) }
            VisibleDetailLayout(width: width) {
                content.environment(\.pageTargetWidth, target)
            }
                .clipShape(PageClip())
                .animation(nil, value: width)
        }
    }
}

extension EnvironmentValues {
    /// The width the page has, or is on its way to while the Agent panel opens or closes. Pages
    /// choose their arrangement by it, so it is settled when the motion starts, not during or after.
    @Entry var pageTargetWidth: CGFloat?
}

/// Propose the visible width without declaring a fixed minimum width to the native split.
/// It has no intrinsic width: the native split supplies a finite allocation during layout.
struct VisibleDetailLayout: Layout {
    var width: CGFloat

    /// No alignment guides of its own: the default placed every subview again to find them.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.replacingUnspecifiedDimensions(by: .zero)
        return CGSize(width: min(width, proposed.width), height: proposed.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

enum SplitDetailLayout {
    nonisolated static func visibleWidth(proposed: CGFloat, split: CGFloat, leading: CGFloat) -> CGFloat {
        max(0, min(proposed, split - leading))
    }
}

/// The page's clip. On macOS 26 only at the sides and the bottom: above, scrolling content passes
/// under the window's top row, where the system softens it (see `TopRowBar`). Before macOS 26 nothing
/// softens it, so the page is clipped below the row as well.
struct PageClip: Shape {
    nonisolated static let softensAbove: Bool = { if #available(macOS 26, *) { true } else { false } }()

    nonisolated func path(in rect: CGRect) -> Path {
        let above: CGFloat = Self.softensAbove ? MainView.topRowHeight : 0
        return Path(CGRect(x: rect.minX, y: rect.minY - above, width: rect.width, height: rect.height + above))
    }
}
