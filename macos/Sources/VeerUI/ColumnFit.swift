import CoreGraphics

/// Which of a table's columns to hide so that the rest fit its width, rather than leaving some past
/// the edge to scroll to. A table narrows beside a route or the Agent panel.
public enum ColumnFit {
    /// The room AppKit puts between columns, and around their content.
    public static let spacing: CGFloat = 17

    public struct Column: Sendable {
        public init(_ id: String, ideal: CGFloat) {
            self.id = id
            self.ideal = ideal
        }

        public let id: String
        public let ideal: CGFloat
    }

    /// Takes columns away in the order of `givingUp`, least needed first, until the rest fit.
    public static func hidden(in width: CGFloat, columns: [Column], givingUp order: [String]) -> Set<String> {
        var used = columns.reduce(0) { $0 + $1.ideal + spacing }
        var hidden = Set<String>()
        for id in order where used > width {
            guard let column = columns.first(where: { $0.id == id }) else { continue }
            used -= column.ideal + spacing
            hidden.insert(id)
        }
        return hidden
    }
}
