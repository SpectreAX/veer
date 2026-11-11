import AppKit
import Observation
import SwiftUI

/// NavigationSplitView's collapse can reuse a stale detail snapshot and grow the window on
/// reversal. Animate the real native divider instead; SwiftUI exposes no live divider control.
@Observable public final class SidebarAnimator {
    public private(set) var isHidden: Bool
    public private(set) var nativeHidden: Bool
    public private(set) var isAnimating = false
    public private(set) var width: CGFloat = 200
    public private(set) var request = 0

    @ObservationIgnored private weak var controller: NSSplitViewController?
    @ObservationIgnored private weak var item: NSSplitViewItem?
    @ObservationIgnored private weak var detail: NSSplitViewItem?
    @ObservationIgnored private var oldBehavior = NSSplitViewItem.CollapseBehavior.default
    @ObservationIgnored private var oldSafeArea = false
    @ObservationIgnored private var oldResizeCollapse = true
    @ObservationIgnored private var oldMinimum: CGFloat = 180
    @ObservationIgnored private var oldMaximum: CGFloat = 260
    @ObservationIgnored private var animation: DividerAnimation?
    private var currentWidth: CGFloat = 200
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending = false

    public init(isHidden: Bool = false) {
        self.isHidden = isHidden
        nativeHidden = isHidden
    }

    public var minimumWidth: CGFloat { isAnimating ? 0 : 180 }
    public var maximumWidth: CGFloat { isAnimating ? currentWidth : 260 }

    public func rememberWidth(_ value: CGFloat) {
        if !isAnimating, !isHidden, (180...260).contains(value), abs(value - width) > 0.5 { width = value }
    }

    public func nativeVisibilityChanged(hidden: Bool) {
        guard !isAnimating else { return }
        nativeHidden = hidden
        isHidden = hidden
    }

    public func toggle(reduceMotion: Bool) {
        stopAnimation()
        request += 1
        isHidden.toggle()
        guard let item else { nativeHidden = isHidden; return }
        if !isAnimating { currentWidth = item.isCollapsed ? 0 : width }
        isAnimating = true
        pending = !reduceMotion
        if reduceMotion {
            prepare()
            position(isHidden ? 0 : width)
            finish()
        }
    }

    func connect(from view: NSView) {
        var ancestor = view.superview
        while let parent = ancestor {
            if let split = parent as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                guard item !== sidebar else { return }
                disconnect()
                self.controller = controller
                item = sidebar
                oldBehavior = sidebar.collapseBehavior
                oldMinimum = sidebar.minimumThickness
                oldMaximum = sidebar.maximumThickness
                oldResizeCollapse = sidebar.canCollapseFromWindowResize
                sidebar.collapseBehavior = .useConstraints
                // Inline columns get real bounds each frame. Overlay safe-area updates otherwise
                // arrive separately from the native column geometry on macOS 26 and later.
                if #available(macOS 26.0, *), let detail = controller.splitViewItems.last, detail !== sidebar {
                    self.detail = detail
                    oldSafeArea = detail.automaticallyAdjustsSafeAreaInsets
                    detail.automaticallyAdjustsSafeAreaInsets = false
                }
                return
            }
            ancestor = parent.superview
        }
    }

    /// Defer until SwiftUI has committed the temporary zero minimum and visibility binding.
    func startPendingAnimation() {
        guard pending else { return }
        pending = false
        let request = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == request, item != nil else { return }
            prepare()
            let start = currentWidth, end = isHidden ? 0 : width
            let driver = DividerAnimation { [weak self] progress in
                self?.position(start + (end - start) * progress)
            } completion: { [weak self] in self?.finish() }
            animation = driver
            driver.start()
        }
    }

    private func prepare() {
        item?.minimumThickness = 0
        item?.maximumThickness = currentWidth
        item?.canCollapseFromWindowResize = false
        item?.isCollapsed = false
        nativeHidden = false
    }

    private func position(_ value: CGFloat) {
        guard isAnimating else { return }
        currentWidth = max(0, value)
        item?.maximumThickness = currentWidth
        controller?.splitView.setPosition(currentWidth, ofDividerAt: 0)
        controller?.view.layoutSubtreeIfNeeded()
    }

    private func finish() {
        animation = nil
        item?.isCollapsed = isHidden
        nativeHidden = isHidden
        item?.minimumThickness = oldMinimum
        item?.maximumThickness = oldMaximum
        item?.canCollapseFromWindowResize = oldResizeCollapse
        isAnimating = false
    }

    private func stopAnimation() {
        generation += 1
        pending = false
        animation?.delegate = nil
        animation?.stop()
        animation = nil
    }

    func disconnect() {
        stopAnimation()
        if item != nil { finish() }
        item?.collapseBehavior = oldBehavior
        if #available(macOS 26.0, *) { detail?.automaticallyAdjustsSafeAreaInsets = oldSafeArea }
        controller = nil
        item = nil
        detail = nil
    }
}

nonisolated final class DividerAnimation: NSAnimation, NSAnimationDelegate {
    let apply: @MainActor (CGFloat) -> Void
    let completion: @MainActor () -> Void

    init(apply: @escaping @MainActor (CGFloat) -> Void, completion: @escaping @MainActor () -> Void) {
        self.apply = apply
        self.completion = completion
        super.init(duration: Motion.standardDuration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
        delegate = self
    }
    required init?(coder: NSCoder) { nil }
    override var currentProgress: NSAnimation.Progress {
        didSet {
            // Nonblocking NSAnimation runs on its starting run loop; SidebarAnimator starts on main.
            let apply = apply, value = CGFloat(currentValue)
            MainActor.assumeIsolated { apply(value) }
        }
    }
    func animationDidEnd(_ animation: NSAnimation) {
        let completion = completion
        MainActor.assumeIsolated { completion() }
    }
}

/// Attach inside the sidebar, so only that window and split controller are configured.
public struct SidebarAnimationHost: NSViewRepresentable {
    let animator: SidebarAnimator
    let request: Int
    public init(_ animator: SidebarAnimator) { self.animator = animator; request = animator.request }
    public func makeNSView(context: Context) -> NSView { Connector(animator: animator) }
    public func updateNSView(_ view: NSView, context: Context) {
        (view as? Connector)?.connect()
        if request == animator.request { animator.startPendingAnimation() }
    }
    public static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let connector = view as? Connector else { return }
        connector.isActive = false
        connector.animator.disconnect()
    }

    final class Connector: NSView {
        let animator: SidebarAnimator
        var isActive = true
        init(animator: SidebarAnimator) {
            self.animator = animator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                connect()
            }
        }
        func connect() { if isActive { animator.connect(from: self) } }
    }
}
