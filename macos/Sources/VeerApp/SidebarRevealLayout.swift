import SwiftUI

/// Keep sidebar labels at their resting width while the real native column reveals them.
/// Unlike a fixed frame this layout advertises a zero minimum to the native split.
struct SidebarRevealLayout: Layout {
    var width: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = width ?? bounds.width
        subviews.first?.place(at: CGPoint(x: bounds.maxX - width, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}
