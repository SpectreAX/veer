import SwiftUI

/// What a page is told while a panel beside it opens or closes: how much wider (or, negative,
/// narrower) it will be at the end. Nil at rest. Set before the motion starts, and constant
/// through it; a reversal is a new motion.
nonisolated public struct PanelMotion: Equatable, Sendable {
    public let id: Int
    public let widthChange: CGFloat

    public init(id: Int, widthChange: CGFloat) {
        self.id = id
        self.widthChange = widthChange
    }
}

extension EnvironmentValues {
    @Entry public var panelMotion: PanelMotion?
}

/// The latest width a view was given, read when a motion starts. A reference held in state, so
/// writing it at every frame of a motion does not update the view.
public final class LatestWidth {
    public var value: CGFloat = 0
    public init() {}
}

/// An adaptive lazy grid whose column count holds while a panel beside the page moves. At each
/// width on the way it would take a new count, two or three times in a motion, each time moving
/// every item; and each new count cost a frame. It keeps the count of the narrower end, so items
/// only widen and narrow on the way, and at rest goes back to fitting what it has, once.
public struct SteadyGrid<Content: View>: View {
    let minimum: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat?
    let alignment: HorizontalAlignment
    @ViewBuilder let content: Content
    @Environment(\.panelMotion) private var motion
    /// Read when a motion starts; kept out of state, as it changes at every frame of one.
    @State private var width = LatestWidth()
    @State private var held: Int?

    /// `spacing` is between columns, and between rows unless `rowSpacing` says otherwise.
    public init(minimum: CGFloat, spacing: CGFloat, rowSpacing: CGFloat? = nil, alignment: HorizontalAlignment = .center,
                @ViewBuilder content: () -> Content) {
        self.minimum = minimum
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
        self.content = content()
    }

    /// As many as fit, as `GridItem.adaptive` counts them.
    public static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, minimum + spacing > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The count for a motion starting at `width`: what fits at its narrower end.
    public static func heldColumns(width: CGFloat, motion: PanelMotion, minimum: CGFloat, spacing: CGFloat) -> Int {
        columns(width: min(width, width + motion.widthChange), minimum: minimum, spacing: spacing)
    }

    private var items: [GridItem] {
        if let held { return Array(repeating: GridItem(.flexible(), spacing: spacing), count: held) }
        return [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
    }

    public var body: some View {
        LazyVGrid(columns: items, alignment: alignment, spacing: rowSpacing ?? spacing) { content }
            // A new count takes effect at once: animated, each item travels to its new place on its
            // own and they cross over each other.
            .animation(nil, value: held)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
            .onChange(of: motion, initial: true) { _, motion in
                // A reversal part way is a new motion between the same two ends: the count chosen at
                // the start holds. Worked out again from the middle, it took the far end one panel
                // further and changed the count twice.
                guard let motion else { return held = nil }
                if held == nil { held = Self.heldColumns(width: width.value, motion: motion, minimum: minimum, spacing: spacing) }
            }
    }
}

/// `ViewThatFits` with two arrangements, for a row whose width is known, whose choice holds while a
/// panel moves, as `SteadyGrid` holds its count: `ViewThatFits` alone decides again at every width
/// on the way. At rest it is `ViewThatFits` itself. Through a motion the row reports an ideal width
/// that always or never fits, so the same views stay and only the choice is fixed.
public struct SteadyChoice<Wide: View, Narrow: View>: View {
    let requiredWidth: CGFloat?
    @ViewBuilder let wide: Wide
    @ViewBuilder let narrow: Narrow
    @Environment(\.panelMotion) private var motion
    @State private var width = LatestWidth()
    @State private var held: Bool?

    /// Without `requiredWidth` the choice is not held: `ViewThatFits` alone.
    public init(requiredWidth: CGFloat?, @ViewBuilder wide: () -> Wide, @ViewBuilder narrow: () -> Narrow) {
        self.requiredWidth = requiredWidth
        self.wide = wide()
        self.narrow = narrow()
    }

    /// Whether the row is shown through a motion starting at `width`: if it fits at the narrower end.
    public static func heldFits(width: CGFloat, motion: PanelMotion, requiredWidth: CGFloat) -> Bool {
        min(width, width + motion.widthChange) >= requiredWidth
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            wide.frame(idealWidth: held.map { $0 ? 0 : .greatestFiniteMagnitude })
            narrow
        }
        // Its width is what it is offered, which is what the choice is made in.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
        .onChange(of: motion, initial: true) { _, motion in
            // As `SteadyGrid`: the choice made at the start of a motion holds through a reversal.
            guard let motion else { return held = nil }
            if held == nil { held = requiredWidth.map { Self.heldFits(width: width.value, motion: motion, requiredWidth: $0) } }
        }
    }
}
