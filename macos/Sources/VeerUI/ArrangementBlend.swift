import SwiftUI

/// One item in one arrangement of a row layout: where it is across, which row it is in, and how
/// tall its row makes it.
nonisolated public struct ArrangedItem: Equatable, Sendable {
    public var x: CGFloat
    public var width: CGFloat
    public var row: Int
    public var height: CGFloat

    public init(x: CGFloat, width: CGFloat, row: Int, height: CGFloat) {
        self.x = x
        self.width = width
        self.row = row
        self.height = height
    }
}

/// Carries a set of items from one arrangement to another as a function of the width they are laid
/// out in, so a page whose width is animated changes arrangement continuously: no value of its own
/// to animate, nothing held and switched afterward, and turning back part way retraces the same path.
///
/// Both arrangements are computed at the current width. From the narrow end to the wide one, items
/// first move and resize across, each in the row it has, until they stand where the wide arrangement
/// wants them; then they move to their rows there, and what is below follows. Two items never cross
/// that way when each of the narrow arrangement's rows keeps its items in order.
nonisolated public enum ArrangementBlend {
    /// 0 at the narrow end of `range`, 1 at the wide end.
    public static func progress(width: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 1 }
        return min(max((width - range.lowerBound) / span, 0), 1)
    }

    /// The part of the way spent moving across; the rest is spent changing rows. Items stand
    /// side by side from here on, each no wider than its share of the width at this point, so the
    /// later it is, the less they narrow below what they end up with.
    public static let acrossShare: CGFloat = 0.6

    /// Across first, then between rows.
    public static func phases(_ progress: CGFloat) -> (across: CGFloat, rows: CGFloat) {
        (min(1, progress / acrossShare), max(0, (progress - acrossShare) / (1 - acrossShare)))
    }

    /// Each item's frame, `narrow` at progress 0 and `wide` at 1, rows `spacing` apart.
    public static func frames(narrow: [ArrangedItem], wide: [ArrangedItem], spacing: CGFloat, progress: CGFloat) -> [CGRect] {
        let (across, rows) = phases(progress)
        func mix(_ from: CGFloat, _ to: CGFloat, _ amount: CGFloat) -> CGFloat { from + (to - from) * amount }
        let count = min(narrow.count, wide.count)
        let heights = (0..<count).map { mix(narrow[$0].height, wide[$0].height, across) }
        // Where each arrangement's rows start, stacked with the heights the items have now, so
        // nothing overlaps while they still change.
        func tops(_ items: [ArrangedItem]) -> [CGFloat] {
            let rowCount = (items.prefix(count).map(\.row).max() ?? -1) + 1
            var rowHeights = [CGFloat](repeating: 0, count: rowCount)
            for index in 0..<count { rowHeights[items[index].row] = max(rowHeights[items[index].row], heights[index]) }
            var result: [CGFloat] = [], y: CGFloat = 0
            for height in rowHeights {
                result.append(y)
                y += height + spacing
            }
            return (0..<count).map { result[items[$0].row] }
        }
        let narrowTops = tops(narrow), wideTops = tops(wide)
        return (0..<count).map { index in
            CGRect(x: mix(narrow[index].x, wide[index].x, across), y: mix(narrowTops[index], wideTops[index], rows),
                   width: mix(narrow[index].width, wide[index].width, across), height: heights[index])
        }
    }
}

/// An adaptive grid, as many equal columns as fit, whose items go from one column count to another
/// with the width while a panel beside the page moves (`ArrangementBlend`). Not lazy: for a handful
/// of items. `SteadyGrid` is the lazy one, which holds its count instead.
public struct BlendedGrid<Content: View>: View {
    let minimum: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.panelMotion) private var motion
    @State private var width = LatestWidth()
    /// The grid's widths at the two ends of the motion, while it lasts.
    @State private var motionWidths: ClosedRange<CGFloat>?

    public init(minimum: CGFloat, spacing: CGFloat, rowSpacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.minimum = minimum
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content()
    }

    /// The widths at the two ends of a motion starting at `width`.
    public static func motionWidths(width: CGFloat, motion: PanelMotion) -> ClosedRange<CGFloat> {
        max(0, min(width, width + motion.widthChange))...max(0, width, width + motion.widthChange)
    }

    public var body: some View {
        BlendedGridLayout(minimum: minimum, spacing: spacing, rowSpacing: rowSpacing, motionWidths: motionWidths) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
            .onChange(of: motion, initial: true) { _, motion in
                // A reversal part way is the same motion between the same two ends.
                if let motion {
                    if motionWidths == nil { motionWidths = Self.motionWidths(width: width.value, motion: motion) }
                } else {
                    motionWidths = nil
                }
            }
    }
}

nonisolated public struct BlendedGridLayout: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var motionWidths: ClosedRange<CGFloat>?

    public static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, minimum + spacing > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// `count` items in `columns` equal columns of a grid `width` wide, heights left to measure.
    public static func items(count: Int, columns: Int, width: CGFloat, spacing: CGFloat) -> [ArrangedItem] {
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        return (0..<count).map { ArrangedItem(x: CGFloat($0 % columns) * (columnWidth + spacing), width: columnWidth, row: $0 / columns, height: 0) }
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    private func measured(columns: Int, width: CGFloat, subviews: Subviews) -> [ArrangedItem] {
        var items = Self.items(count: subviews.count, columns: columns, width: width, spacing: spacing)
        let heights = items.indices.map { subviews[$0].sizeThatFits(.init(width: items[$0].width, height: nil)).height }
        for index in items.indices {
            let row = items[index].row
            items[index].height = heights[(row * columns)..<min((row + 1) * columns, heights.count)].max() ?? 0
        }
        return items
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = { Self.columns(width: $0, minimum: minimum, spacing: spacing) }
        if let motionWidths, columns(motionWidths.lowerBound) != columns(motionWidths.upperBound) {
            return ArrangementBlend.frames(narrow: measured(columns: columns(motionWidths.lowerBound), width: width, subviews: subviews),
                                           wide: measured(columns: columns(motionWidths.upperBound), width: width, subviews: subviews),
                                           spacing: rowSpacing, progress: ArrangementBlend.progress(width: width, range: motionWidths))
        }
        let items = measured(columns: columns(width), width: width, subviews: subviews)
        return ArrangementBlend.frames(narrow: items, wide: items, spacing: rowSpacing, progress: 1)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A header of four parts, in this order: a title, a badge, a detail and trailing actions. On one
/// line when it all fits; else the badge and detail take a second line. While a panel beside the
/// page moves, the same four views go from one form to the other with the width
/// (`ArrangementBlend`), so the header's height, and everything below it, changes continuously.
/// The detail is given the width there is, and truncates in it, in either form.
public struct BlendedHeader<Content: View>: View {
    let spacing: CGFloat
    let rowSpacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.panelMotion) private var motion
    @State private var width = LatestWidth()
    @State private var motionWidths: ClosedRange<CGFloat>?

    public init(spacing: CGFloat, rowSpacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content()
    }

    public var body: some View {
        BlendedHeaderLayout(spacing: spacing, rowSpacing: rowSpacing, motionWidths: motionWidths) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
            .onChange(of: motion, initial: true) { _, motion in
                if let motion {
                    if motionWidths == nil { motionWidths = BlendedGrid<EmptyView>.motionWidths(width: width.value, motion: motion) }
                } else {
                    motionWidths = nil
                }
            }
    }
}

nonisolated public struct BlendedHeaderLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var motionWidths: ClosedRange<CGFloat>?

    /// The parts' own sizes: title, badge, detail, actions.
    public struct Parts: Equatable, Sendable {
        public var title: CGSize
        public var badge: CGSize
        public var detail: CGSize
        public var actions: CGSize

        public init(title: CGSize, badge: CGSize, detail: CGSize, actions: CGSize) {
            self.title = title
            self.badge = badge
            self.detail = detail
            self.actions = actions
        }
    }

    /// What one line needs: every part whole, a gap between each.
    public static func oneLineWidth(_ parts: Parts, spacing: CGFloat) -> CGFloat {
        let widths = [parts.title.width, parts.badge.width, parts.detail.width, parts.actions.width].filter { $0 > 0 }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
    }

    /// The four parts on one line (`oneLine`) or two, in a header `width` wide. The detail never
    /// runs under the actions: it gets what is left before them.
    public static func items(_ parts: Parts, oneLine: Bool, width: CGFloat, spacing: CGFloat) -> [ArrangedItem] {
        let actionsX = max(0, width - parts.actions.width)
        let beforeActions = max(0, actionsX - (parts.actions.width > 0 ? spacing : 0))
        let titleWidth = min(parts.title.width, beforeActions)
        if oneLine {
            let badgeX = titleWidth + (parts.badge.width > 0 ? spacing : 0)
            let detailX = badgeX + parts.badge.width + (parts.detail.width > 0 ? spacing : 0)
            let height = max(parts.title.height, parts.badge.height, parts.detail.height, parts.actions.height)
            return [ArrangedItem(x: 0, width: titleWidth, row: 0, height: height),
                    ArrangedItem(x: badgeX, width: min(parts.badge.width, max(0, beforeActions - badgeX)), row: 0, height: height),
                    ArrangedItem(x: detailX, width: min(parts.detail.width, max(0, beforeActions - detailX)), row: 0, height: height),
                    ArrangedItem(x: actionsX, width: parts.actions.width, row: 0, height: height)]
        }
        let first = max(parts.title.height, parts.actions.height), second = max(parts.badge.height, parts.detail.height)
        let detailX = parts.badge.width + (parts.badge.width > 0 ? spacing : 0)
        return [ArrangedItem(x: 0, width: titleWidth, row: 0, height: first),
                ArrangedItem(x: 0, width: min(parts.badge.width, width), row: 1, height: second),
                ArrangedItem(x: detailX, width: min(parts.detail.width, max(0, width - detailX)), row: 1, height: second),
                ArrangedItem(x: actionsX, width: parts.actions.width, row: 0, height: first)]
    }

    /// Each part's frame in a header `width` wide, part way through a motion or at rest.
    public static func frames(_ parts: Parts, width: CGFloat, spacing: CGFloat, rowSpacing: CGFloat,
                              motionWidths: ClosedRange<CGFloat>?) -> [CGRect] {
        let needed = oneLineWidth(parts, spacing: spacing)
        if let motionWidths, (motionWidths.lowerBound >= needed) != (motionWidths.upperBound >= needed) {
            return ArrangementBlend.frames(narrow: items(parts, oneLine: false, width: width, spacing: spacing),
                                           wide: items(parts, oneLine: true, width: width, spacing: spacing),
                                           spacing: rowSpacing, progress: ArrangementBlend.progress(width: width, range: motionWidths))
        }
        // In a motion that keeps one form, that form; at rest, the one the width calls for.
        let oneLine = (motionWidths?.lowerBound ?? width) >= needed
        let arranged = items(parts, oneLine: oneLine, width: width, spacing: spacing)
        return ArrangementBlend.frames(narrow: arranged, wide: arranged, spacing: rowSpacing, progress: 1)
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        // The actions take what they need first, short of leaving the title nothing.
        let actions = subviews[3].sizeThatFits(ProposedViewSize(width: max(0, width - 80), height: nil))
        let parts = Parts(title: subviews[0].sizeThatFits(.unspecified), badge: subviews[1].sizeThatFits(.unspecified),
                          detail: subviews[2].sizeThatFits(.unspecified), actions: actions)
        return Self.frames(parts, width: width, spacing: spacing, rowSpacing: rowSpacing, motionWidths: motionWidths)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            // Each part centered in its row's height, at its place across.
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
