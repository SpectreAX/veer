import AppKit
import SwiftUI

/// Keep both columns in SwiftUI's view tree (including preferences and focus). SwiftUI exposes no
/// live split-divider animation, so the bridge moves HSplitView's actual AppKit divider.
public struct PanelSplitView<Content: View, Panel: View>: View {
    let isPresented: Bool
    @Binding var width: Double
    @State private var retainPanel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animationTrigger: Bool
    let growsWindow: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let panel: Panel

    /// `growsWindow`: opening the panel widens the window by the panel's width, and closing it
    /// gives that width back, so the page keeps its width (see `PanelWindowGrowth`).
    public init(isPresented: Bool, width: Binding<Double>, animationTrigger: Bool? = nil, growsWindow: Bool = false,
                @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.isPresented = isPresented
        _width = width
        self.growsWindow = growsWindow
        self.animationTrigger = animationTrigger ?? isPresented
        self.content = content()
        self.panel = panel()
    }

    private var panelWidth: CGFloat { PanelSplitMetrics.width(width) }

    public var body: some View {
        GeometryReader { geometry in
            HSplitView {
                content
                    .environment(\.panelContentTargetWidth, max(0, geometry.size.width - (isPresented ? panelWidth : 0) - 1))
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                PanelContentLayout(width: panelWidth) {
                    if isPresented || retainPanel { panel }
                }
                    .frame(minWidth: 0, maxWidth: 520, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(!isPresented)
                    .allowsHitTesting(isPresented)
                    .disabled(!isPresented)
                    .background(PanelDividerHost(presented: isPresented, width: $width, animated: !reduceMotion,
                                                 trigger: animationTrigger, growsWindow: growsWindow,
                                                 closed: { retainPanel = false }))
            }
        }
        .onChange(of: isPresented, initial: true) { if isPresented { retainPanel = true } }
    }
}

/// A partially revealed panel keeps its resting width, without imposing that intrinsic minimum on
/// the native column. The page always receives the real space left beside that column.
private struct PanelContentLayout: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

private struct PanelDividerHost: NSViewRepresentable {
    let presented: Bool
    @Binding var width: Double
    let animated: Bool
    let trigger: Bool
    let growsWindow: Bool
    let closed: () -> Void

    func makeNSView(context: Context) -> PanelDividerConnector { PanelDividerConnector() }

    func updateNSView(_ view: PanelDividerConnector, context: Context) {
        view.growsWindow = growsWindow
        view.configure(presented: presented, width: width, animated: animated, trigger: trigger, closed: closed) { width = $0 }
    }

    static func dismantleNSView(_ view: PanelDividerConnector, coordinator: ()) { view.disconnect() }
}

final class PanelDividerConnector: NSView {
    var growsWindow = false
    /// The window's frame before opening widened it, and the frame it was widened to: closing puts
    /// back the first while the person has not moved or resized the window since.
    private var frameBeforeGrowing: NSRect?
    private var grownFrame: NSRect?
    private weak var split: NSSplitView?
    private var driver: PanelDividerAnimation?
    private var trigger: Bool?
    private var splitWidth: CGFloat = 0
    private var presented = false
    private var restingWidth: CGFloat = 380
    private var resizeObserver: NSObjectProtocol?
    private var applying = false
    private var attached = false
    private var active = true
    private var closed: (() -> Void)?
    private var widthChanged: ((Double) -> Void)?

    func configure(presented: Bool, width: Double, animated: Bool, trigger: Bool? = nil,
                   closed: (() -> Void)? = nil, widthChanged: @escaping (Double) -> Void) {
        // Opened or closed by the person, not shown or hidden by a page switch.
        let toggled = self.trigger != nil && self.trigger != (trigger ?? presented)
        let shouldAnimate = animated && self.trigger != (trigger ?? presented)
        self.trigger = trigger ?? presented
        let changed = self.presented != presented || abs(restingWidth - PanelSplitMetrics.width(width)) > 0.5
        self.presented = presented
        restingWidth = PanelSplitMetrics.width(width)
        self.widthChanged = widthChanged
        self.closed = closed
        connect()
        if attached, changed || (!animated && driver != nil) { move(animated: shouldAnimate, resizesWindow: toggled) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.connect() }
    }

    private func connect() {
        guard active, !attached, window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.arrangedSubviews.count == 2 {
                self.split = split
                attached = true
                resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                                         object: split, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resized() }
                }
                move(animated: false, resizesWindow: false)
                return
            }
            ancestor = view.superview
        }
    }

    /// `resizesWindow` only for the person's own toggle: a page switch (to the Agent page and back)
    /// or the window being restored at launch leaves the window's size alone.
    private func move(animated: Bool, resizesWindow: Bool) {
        driver?.stop()
        driver = nil
        guard let split else { return }
        if !presented, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: split.arrangedSubviews[1]) {
            window?.makeFirstResponder(nil)
        }
        let start = split.arrangedSubviews[1].frame.width
        let target = presented ? restingWidth : 0
        // A window resized at every frame redraws its whole surface each time and hitched on nearly
        // every frame (137 to 142 per 18 toggles against 17 to 30 squeezing the page). So, as
        // Telegram Desktop does, the window takes its new size at once, with the panel.
        if resizesWindow, let frames = windowFrames(panelChange: target - start) {
            setWindowFrame(frames.to)
            position(target)
            window?.displayIfNeeded()
            didSettle()
            return
        }
        guard animated, abs(start - target) > 0.5 else {
            position(target)
            didSettle()
            return
        }
        let animation = PanelDividerAnimation { [weak self] progress in
            self?.position(start + (target - start) * progress)
        } completion: { [weak self] in
            self?.driver = nil
            self?.didSettle()
        }
        driver = animation
        // updateNSView can precede the table's column rebuild in the same SwiftUI commit. Start
        // after that commit, so its initial layout doesn't consume the animation's first frames.
        DispatchQueue.main.async { [weak self, weak animation] in
            guard let self, active, let animation, driver === animation else { return }
            split.layoutSubtreeIfNeeded()
            animation.start()
        }
    }

    /// Where the window goes as the panel opens or closes, or nil when it keeps its size: not
    /// asked to, full screen, zoomed, or nothing to do.
    private func windowFrames(panelChange: CGFloat) -> (from: NSRect, to: NSRect)? {
        guard growsWindow, let window, let screen = window.screen, abs(panelChange) > 0.5,
              !window.styleMask.contains(.fullScreen), !window.isZoomed else { return nil }
        let frame = window.frame
        let target: NSRect
        if panelChange > 0 {
            target = PanelWindowGrowth.grown(frame, by: panelChange, within: screen.visibleFrame)
            frameBeforeGrowing = frame
            grownFrame = target
        } else if let before = frameBeforeGrowing, let grown = grownFrame, PanelWindowGrowth.same(frame, grown) {
            target = before
        } else {
            // Moved or resized meanwhile: give back what opening added, which the screen's width may
            // have capped; opened before this launch, the panel's width.
            let added = frameBeforeGrowing.flatMap { before in grownFrame.map { $0.width - before.width } } ?? -panelChange
            target = PanelWindowGrowth.shrunk(frame, by: added, minWidth: window.minSize.width)
        }
        if panelChange < 0 { frameBeforeGrowing = nil; grownFrame = nil }
        return PanelWindowGrowth.same(frame, target) ? nil : (frame, target)
    }

    /// Drawn with the divider's move that follows, never at the in-between width.
    private func setWindowFrame(_ frame: NSRect) {
        applying = true
        window?.setFrame(frame, display: false)
        applying = false
    }

    private func didSettle() {
        guard !presented else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, active, !presented, driver == nil else { return }
            closed?()
        }
    }

    private func position(_ width: CGFloat) {
        guard let split else { return }
        splitWidth = split.bounds.width
        applying = true
        // This public operation also updates HSplitView's hosting proposals. Assigning only
        // child frames leaves SwiftUI drawing the old width until the endpoint.
        split.setPosition(max(0, split.bounds.width - split.dividerThickness - width), ofDividerAt: 0)
        applying = false
    }

    private func resized() {
        guard !applying, driver == nil, let split else { return }
        if abs(split.bounds.width - splitWidth) > 0.5 {
            position(presented ? restingWidth : 0)
            return
        }
        let width = split.arrangedSubviews[1].frame.width
        if !presented { position(0); return }
        let clamped = min(520, max(320, width))
        if abs(width - clamped) > 0.5 { position(clamped) }
        guard abs(clamped - restingWidth) > 0.5 else { return }
        restingWidth = clamped
        DispatchQueue.main.async { [weak self] in
            guard let self, active, abs(restingWidth - clamped) < 0.5 else { return }
            widthChanged?(Double(clamped))
        }
    }

    func disconnect() {
        active = false
        driver?.stop()
        driver = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        split = nil
        widthChanged = nil
        closed = nil
    }
}

nonisolated private final class PanelDividerAnimation: NSAnimation {
    let apply: @MainActor (CGFloat) -> Void
    let completion: @MainActor () -> Void

    init(apply: @escaping @MainActor (CGFloat) -> Void, completion: @escaping @MainActor () -> Void) {
        self.apply = apply
        self.completion = completion
        super.init(duration: Motion.standardDuration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { nil }

    override var currentProgress: NSAnimation.Progress {
        didSet {
            let apply = apply, completion = completion, value = CGFloat(currentValue), finished = currentProgress >= 1
            MainActor.assumeIsolated {
                apply(value)
                if finished { completion() }
            }
        }
    }
}

extension EnvironmentValues {
    /// The leading column's destination width. Discrete grid/column choices can be made once,
    /// while the native divider supplies each real intermediate width.
    @Entry public var panelContentTargetWidth: CGFloat?
}

/// How the window makes room for a panel, as Telegram Desktop does for its third column: wider to
/// the right; without room there, also moved left; never wider than the screen. Closing gives the
/// width back.
nonisolated public enum PanelWindowGrowth {
    public static func grown(_ frame: CGRect, by amount: CGFloat, within visible: CGRect) -> CGRect {
        let width = min(frame.width + amount, max(frame.width, visible.width))
        let x = max(min(frame.minX, visible.maxX - width), min(frame.minX, visible.minX))
        return CGRect(x: x, y: frame.minY, width: width, height: frame.height)
    }

    public static func shrunk(_ frame: CGRect, by amount: CGFloat, minWidth: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: max(minWidth, frame.width - amount), height: frame.height)
    }

    public static func same(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.5 && abs(first.minY - second.minY) < 0.5
            && abs(first.width - second.width) < 0.5 && abs(first.height - second.height) < 0.5
    }
}

enum PanelSplitMetrics {
    static func width(_ saved: Double) -> CGFloat { (320...520).contains(saved) ? saved : 380 }
}
