import SwiftUI

/// The column count for rows of equal tiles that a lazy stack makes one row at a time, from the
/// width it is laid out in, held while a panel beside the page moves as `SteadyGrid` holds its own.
///
/// A `LazyVGrid` measures every item to know its own height: in a lazy list of sections, a few
/// hundred tiles each, expanding them all measured every tile of every section at once. Rows in a
/// lazy stack are measured only as they come into view, the rest estimated, so the content reads
/// one count for the whole list (the same in every section) and chunks its items into rows.
public struct SteadyColumns<Content: View>: View {
    let minimum: CGFloat
    let spacing: CGFloat
    /// What lies between this view's edges and the rows': a section's padding on each side.
    let inset: CGFloat
    let content: (Int) -> Content
    @Environment(\.panelMotion) private var motion
    @State private var width = LatestWidth()
    @State private var count = 1
    @State private var held: Int?

    public init(minimum: CGFloat, spacing: CGFloat, inset: CGFloat = 0, @ViewBuilder content: @escaping (Int) -> Content) {
        self.minimum = minimum
        self.spacing = spacing
        self.inset = inset
        self.content = content
    }

    public var body: some View {
        content(held ?? count)
            // A new count takes effect at once, as in `SteadyGrid`: animated, tiles would cross.
            .animation(nil, value: held ?? count)
            // One reading of the width for both: a second `onGeometryChange` for the count alone missed
            // its last change when the width went down and back up in one update (712, 512, 612 pt as
            // a window first appeared), and the grid kept a column too few.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
                width.value = value
                let fits = SteadyGrid<EmptyView>.columns(width: value - 2 * inset, minimum: minimum, spacing: spacing)
                if fits != count { count = fits }
            }
            .onChange(of: motion, initial: true) { _, motion in
                guard let motion else { return held = nil }
                if held == nil {
                    held = SteadyGrid<EmptyView>.heldColumns(width: width.value - 2 * inset, motion: motion, minimum: minimum, spacing: spacing)
                }
            }
    }

    /// `items` in rows of `columns`, the last one short.
    public static func rows<Item>(_ items: [Item], columns: Int) -> [ArraySlice<Item>] {
        let columns = max(1, columns)
        return stride(from: 0, to: items.count, by: columns).map { items[$0..<min($0 + columns, items.count)] }
    }
}

/// One row of a `SteadyColumns` list: `columns` equal columns `spacing` apart, its subviews in the
/// first of them, centred in the row's height as a grid's are. A short last row keeps the same
/// column widths.
nonisolated public struct EqualColumnsRow: Layout {
    let columns: Int
    let spacing: CGFloat

    public init(columns: Int, spacing: CGFloat) {
        self.columns = max(1, columns)
        self.spacing = spacing
    }

    public static func columnWidth(_ width: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        max(0, (width - CGFloat(max(1, columns) - 1) * spacing) / CGFloat(max(1, columns)))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(columns) * 180 + CGFloat(columns - 1) * spacing
        let column = Self.columnWidth(width, columns: columns, spacing: spacing)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = Self.columnWidth(bounds.width, columns: columns, spacing: spacing)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: column, height: nil))
        }
    }
}
