import SwiftUI

/// NavigationSplitView can lay out its detail at the destination width while AppKit is still
/// moving the column. Keep the page's right edge inside the split at every intermediate position.
struct SplitDetailViewport<Content: View>: View {
    let splitWidth: CGFloat
    let coordinateSpace: Namespace.ID
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let width = SplitDetailLayout.visibleWidth(proposed: geometry.size.width, split: splitWidth,
                                                       leading: geometry.frame(in: .named(coordinateSpace)).minX)
            VisibleDetailLayout(width: width) { content }
                .clipped()
                // The native column supplies the motion; a second width animation would lag it.
                .animation(nil, value: width)
        }
    }
}

/// Propose the visible width without declaring a fixed minimum width to the native split.
/// It has no intrinsic width: the native split supplies a finite allocation during layout.
struct VisibleDetailLayout: Layout {
    var width: CGFloat

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
