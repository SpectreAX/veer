import SwiftUI

/// A page with a panel at its trailing edge, both laid out by one SwiftUI layout. Opening and
/// closing animate a single value, how far the panel has come in: the page gets each real width on
/// the way, and the panel, at its full width, is pushed in from past the window's trailing edge with
/// its leading edge on the page's trailing edge. The window keeps its size.
///
/// Nothing structural changes while the panel moves. Building the panel, removing it, and turning
/// its input on or off each cost from 30 to 120 ms on the main thread; done in the motion's first
/// frame, they froze it there and it resumed most of the way open. They happen before the motion
/// starts or once it has ended.
public struct PanelRevealStack<Content: View, Panel: View>: View {
    let isPresented: Bool
    let panelWidth: CGFloat
    let animationTrigger: Bool
    let keepsPanelMounted: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let panel: Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the layout shows; the only animated value.
    @State private var revealed = false
    @State private var mounted = false
    /// The panel takes clicks, keys and VoiceOver. Changed only at rest.
    @State private var interactive = false
    /// While the panel moves, neither column takes the pointer. Otherwise, at every frame, AppKit
    /// found again what was under it and updated hover, tooltip and cursor areas for each tile, and
    /// the window walked every view under its title bar for the areas that do not drag it: about an
    /// eighth of each frame on a page of many nodes. Switching it costs a page-wide update, so it switches
    /// before the motion starts and after it ends.
    @State private var moving = false
    /// Bumped on every change, so an earlier motion's completion does nothing.
    @State private var generation = 0

    struct Presentation: Equatable {
        let shown: Bool
        let trigger: Bool
        let reduceMotion: Bool

        func animates(from previous: Self) -> Bool {
            shown != previous.shown && trigger != previous.trigger && !reduceMotion
        }
    }

    /// `animationTrigger` is what the person toggles: a change of `isPresented` without it (a page
    /// that has no panel, say) shows or hides the panel at once. With `keepsPanelMounted` the panel
    /// is built while nothing moves and stays, hidden beneath the page, so opening it builds nothing.
    public init(isPresented: Bool, panelWidth: CGFloat, animationTrigger: Bool? = nil, keepsPanelMounted: Bool = false,
                @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.isPresented = isPresented
        self.panelWidth = panelWidth
        self.animationTrigger = animationTrigger ?? isPresented
        self.keepsPanelMounted = keepsPanelMounted
        self.content = content()
        self.panel = panel()
    }

    public var body: some View {
        GeometryReader { geometry in
            PanelRevealLayout(panelWidth: panelWidth, reveal: revealed ? 1 : 0) {
                // Moved as one piece, at its full width: nothing in it is laid out again or animated
                // by the spring on its own. Always one subview, mounted or not, so the page keeps its place in the layout.
                ZStack {
                    if mounted { panel }
                }
                .transaction { if $0.animation == Motion.panel { $0.animation = nil } }
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!interactive)
                .allowsHitTesting(interactive && !moving)
                .disabled(!interactive)
                // From the moment closing starts: the keyboard must not stay in a panel going away.
                .environment(\.panelConcealed, !(isPresented && interactive))
                // After the filter above, so this one value does follow the spring.
                .modifier(PanelPush(panelWidth: panelWidth, reveal: revealed ? 1 : 0))
                .zIndex(Self.panelAbovePage(interactive: interactive, moving: moving) ? 1 : 0)
                content
                    .environment(\.panelContentTargetWidth, max(0, geometry.size.width - (isPresented ? panelWidth : 0)))
                    .environment(\.panelReserve, keepsPanelMounted && !isPresented ? panelWidth : 0)
                    .environment(\.panelMotion, moving ? PanelMotion(id: generation, widthChange: isPresented ? -panelWidth : panelWidth) : nil)
                    // Only the layout moves the page: it gets a real width at every frame and lays
                    // itself out in it. Carried into the page, the spring also animated each shape's
                    // geometry on its own curve, so card backgrounds and borders drifted from the
                    // text and controls placed by the layout.
                    .transaction { if $0.animation == Motion.panel { $0.animation = nil } }
                    .allowsHitTesting(!moving)
            }
            .clipped()
        }
        // As in the split view this replaces, neither column takes a safe area from the window: the
        // page starts at the window's top and keeps its own top row; the panel's caller places it.
        .ignoresSafeArea(.container)
        .onChange(of: Presentation(shown: isPresented, trigger: animationTrigger, reduceMotion: reduceMotion), initial: true) {
            update(from: $0, to: $1)
        }
        .task(id: keepsPanelMounted) {
            // Started once the window is on screen, between frames.
            if keepsPanelMounted { mounted = true } else if !isPresented && !moving { mounted = false }
        }
    }

    /// The panel draws above the page while it is open or moving. Its Liquid Glass shadow falls a few
    /// points past its leading edge, onto the page; with the opaque page on top it was cut off there
    /// along a straight line, which read as a seam left of the panel. A closed panel stays beneath,
    /// or its shadow would show at the window's trailing edge. The order changes with `moving` and
    /// `interactive`, so once before a motion starts and once after it ends, never per frame.
    static func panelAbovePage(interactive: Bool, moving: Bool) -> Bool {
        interactive || moving
    }

    private func update(from old: Presentation, to current: Presentation) {
        generation += 1
        let request = generation
        // Page changes, Reduce Motion and the first appearance switch at once. Removing the old
        // composer now also prevents it observing the Agent page's focus/import requests.
        guard current.animates(from: old) else {
            moving = false
            mounted = current.shown || (keepsPanelMounted && mounted)
            revealed = current.shown
            interactive = current.shown
            return
        }
        moving = true
        let move = {
            withAnimation(Motion.panel, completionCriteria: .logicallyComplete) {
                revealed = current.shown
            } completion: {
                guard generation == request else { return }
                // At rest: removing the panel takes its text field's focus with it.
                moving = false
                interactive = current.shown
                if !current.shown && !keepsPanelMounted { mounted = false }
            }
        }
        // The pointer is switched off, and the panel built if it is not there yet, in this turn of
        // the run loop; the motion starts at the next, from where it is, with nothing left to do.
        if current.shown { mounted = true }
        // A run-loop block, not the main dispatch queue: that queue does not drain while a run loop
        // runs inside one of its own blocks, which left the panel where it was until that ended.
        let start = MainRunLoopWork { if generation == request { move() } }
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { start.run() } }
    }
}

/// Work handed to the main run loop, which runs it on the main thread.
private struct MainRunLoopWork: @unchecked Sendable {
    let run: @MainActor () -> Void
}

/// The page fills what the panel leaves; the panel, always at its full width, starts where the page
/// ends, so it enters from past the trailing edge as one piece while the page gives way. `reveal`
/// is the only animated value. Subviews: the panel, then the page.
public struct PanelRevealLayout: Layout {
    public var panelWidth: CGFloat
    public var reveal: CGFloat

    public init(panelWidth: CGFloat, reveal: CGFloat) {
        self.panelWidth = panelWidth
        self.reveal = reveal
    }

    public var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    /// No alignment guides of its own: the default placed every subview again to find them.
    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    /// The page's width at this point of the motion. The spring's slight overshoot is kept out of
    /// it, so the page never goes past either end.
    public static func pageWidth(total: CGFloat, panelWidth: CGFloat, reveal: CGFloat) -> CGFloat {
        max(0, total - panelWidth * min(max(reveal, 0), 1))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let page = Self.pageWidth(total: bounds.width, panelWidth: panelWidth, reveal: reveal)
        // Laid out once, where it rests; `PanelPush` carries it in from past the trailing edge.
        subviews[0].place(at: CGPoint(x: bounds.maxX - panelWidth, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: panelWidth, height: bounds.height))
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: page, height: bounds.height))
    }
}

/// Carries the panel, as one piece at its full width, from past the trailing edge to where it rests:
/// its leading edge stays on the page's trailing edge, which the layout computes from the same
/// `reveal` on the same spring. A transform, not a placement: moved by the layout, everything in a
/// long conversation was given a new position at every frame.
struct PanelPush: GeometryEffect {
    var panelWidth: CGFloat
    var reveal: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    /// How far the panel still is from its place; the same clamp as the page's width.
    static func offset(panelWidth: CGFloat, reveal: CGFloat) -> CGFloat {
        panelWidth * (1 - min(max(reveal, 0), 1))
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Self.offset(panelWidth: panelWidth, reveal: reveal), y: 0))
    }
}

extension EnvironmentValues {
    /// The leading column's destination width. Discrete grid/column choices can be made once,
    /// while the layout supplies each real intermediate width.
    @Entry public var panelContentTargetWidth: CGFloat?

    /// In a `PanelRevealStack`'s page: the width the panel would take from it if opened now, zero
    /// while it is open or where there is none. An arrangement chosen for the page's width less
    /// this is the same with the panel open or closed, so opening it never re-arranges.
    @Entry public var panelReserve: CGFloat = 0

    /// In a `PanelRevealStack`'s panel: true while it is closed, opening or closing. SwiftUI's
    /// `disabled` does not reach an AppKit text view in it, which must neither take nor keep the
    /// keyboard then: a closed panel stays built beneath the page.
    @Entry public var panelConcealed = false
}

public enum PanelSplitMetrics {
    /// The saved width when it is in range, else the original default.
    public static func width(_ saved: Double) -> CGFloat { (320...520).contains(saved) ? saved : 380 }
}
