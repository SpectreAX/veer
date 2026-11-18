import SwiftUI

/// Where the composer's top is, in the conversation's coordinate space (`SoftenedUnderComposer.space`);
/// nil where nothing softens.
private struct ComposerEdgeKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    var composerEdge: CGFloat? {
        get { self[ComposerEdgeKey.self] }
        set { self[ComposerEdgeKey.self] = newValue }
    }
}

/// A line or card of the conversation softens as it goes under the composer: blurred and faded in
/// proportion to how much of it is there, so the composer's glass has little sharp text to show
/// through. The content only: the glass, its bar and the system's scroll edge are untouched.
///
/// Measured in the Agent panel, with result cards behind the composer: what showed through went
/// from 2.2 to 1.3 in light and from 8.5 to 3.1 in dark. It follows layout, not drawing: a
/// draw-time `visualEffect` on every line kept a layer for each and cost about 47 MB. It goes on
/// each line and card directly: a container wrapping each child slowed the panel's motion. Views
/// taller than `tallest` are containers whose own lines soften instead.
struct SoftenedUnderComposer: ViewModifier {
    static let space = "conversation"
    static let tallest: CGFloat = 120

    @Environment(\.composerEdge) private var edge
    /// In tenths, so a view moving along away from the composer reports no change.
    @State private var under: CGFloat = 0

    /// How much of a view with `frame` is under a composer whose top is at `edge`: 0 to 1, in tenths.
    nonisolated static func fraction(of frame: CGRect, edge: CGFloat?) -> CGFloat {
        guard let edge, frame.height <= tallest else { return 0 }
        return (max(0, min(1, (frame.maxY - edge) / max(frame.height, 24))) * 10).rounded() / 10
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { Self.fraction(of: $0.frame(in: .named(Self.space)), edge: edge) } action: { under = $0 }
            .blur(radius: under * 5)
            .opacity(1 - under * 0.55)
    }
}
