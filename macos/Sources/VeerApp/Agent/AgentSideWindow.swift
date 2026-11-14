import AppKit
import SwiftUI
import VeerUI

/// The Agent panel in a window of its own, attached to the main window's right edge: opening it
/// leaves the page at its full width. It moves, minimizes and closes with the main window.
///
/// AppKit, because SwiftUI cannot attach one window to another (`addChildWindow`) or place a window
/// beside another. A full-screen window has no room beside it, so there the panel stays a column
/// inside the window (`PanelSplitView`).
struct AgentSideWindowConnector: NSViewRepresentable {
    let isPresented: Bool
    let store: ProxyStore
    let agent: AgentStore
    /// For the sidebar's menu command, which reads it from whichever window has the keyboard.
    let sidebar: SidebarAnimator?

    final class Anchor: NSView {
        let controller = AgentSideWindowController()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.attach(to: window)
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.controller.store = store
        anchor.controller.agent = agent
        anchor.controller.sidebar = sidebar
        anchor.controller.setPresented(isPresented, animated: !context.environment.accessibilityReduceMotion)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.controller.setPresented(false, animated: false)
        anchor.controller.attach(to: nil)
    }
}

/// Where the panel goes beside its window: flush against the window's right edge and as tall as it,
/// or, without room for it there, over the window's right side against the screen's edge, below the
/// window's top row so that its controls (the panel's own switch, start and stop) stay in view.
nonisolated enum AgentSidePlacement {
    static func frame(parent: CGRect, visible: CGRect, width: CGFloat, topRow: CGFloat) -> CGRect {
        if parent.maxX + width <= visible.maxX {
            return CGRect(x: parent.maxX, y: parent.minY, width: width, height: parent.height)
        }
        return CGRect(x: visible.maxX - width, y: parent.minY, width: width, height: max(0, parent.height - topRow))
    }

    static func overlaps(parent: CGRect, visible: CGRect, width: CGFloat) -> Bool {
        parent.maxX + width > visible.maxX
    }

    /// The stored width, or the ideal one when it is outside the allowed range.
    static func width(_ stored: Double) -> CGFloat {
        AgentPanelColumn.widths.contains(stored) ? stored : AgentPanelColumn.idealWidth
    }
}

final class AgentSideWindowController: NSObject, NSWindowDelegate {
    var store: ProxyStore?
    var agent: AgentStore?
    var sidebar: SidebarAnimator? {
        didSet { if sidebar !== oldValue { host?.rootView = content() } }
    }
    private weak var parent: NSWindow?
    private var host: NSHostingController<AnyView>?
    private var panel: NSPanel?
    private var presented = false
    /// The main window's moves, resizes and closing.
    private var observers: [NSObjectProtocol] = []
    /// Set while this code moves the panel, so its own frame changes are not read as the user's.
    private var placing = false

    func attach(to window: NSWindow?) {
        guard window !== parent else { return }
        hide(animated: false)
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = []
        parent = window
        guard let window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        // Restored with the window, at launch: the main window keeps the keyboard.
        if presented { show(animated: false, takesKey: false) }
    }

    func setPresented(_ isPresented: Bool, animated: Bool) {
        guard isPresented != presented else { return }
        presented = isPresented
        guard parent != nil else { return }
        if isPresented { show(animated: animated, takesKey: true) } else { hide(animated: animated) }
    }

    private func show(animated: Bool, takesKey: Bool) {
        guard let parent, let panel = panel ?? makePanel() else { return }
        self.panel = panel
        panel.appearance = parent.appearance
        place()
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.alphaValue = animated ? 0 : 1
        // Opened to type in: the composer takes the keyboard. Brought back with the window, it does not.
        if takesKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.standardDuration
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide(animated: Bool) {
        guard let panel else { return }
        let wasKey = panel.isKeyWindow
        let finish = { [weak self] in
            guard let self, self.panel === panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            // Hidden composers must stop observing shared focus and file-import requests before
            // the Agent page creates its own composer.
            panel.contentViewController = nil
            self.host = nil
            self.panel = nil
            panel.alphaValue = 1
            if wasKey, let parent = self.parent, parent.isVisible { parent.makeKey() }
        }
        guard animated else { return finish() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.standardDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Opened again while fading out. Immediate removal (detach or parent close) must
            // still work while presentation is requested, so this guard belongs only here.
            guard let self, !self.presented else { return }
            finish()
        })
    }

    private func place() {
        guard let parent, let panel, let screen = parent.screen ?? NSScreen.main, let store else { return }
        let width = AgentSidePlacement.width(store.agentPanelWidth)
        let frame = AgentSidePlacement.frame(parent: parent.frame, visible: screen.visibleFrame, width: width, topRow: MainView.topRowHeight)
        // Beside the window its top row lines up with the window's; below that row it needs none.
        let overlapping = AgentSidePlacement.overlaps(parent: parent.frame, visible: screen.visibleFrame, width: width)
        if (panel.toolbar == nil) != overlapping { panel.toolbar = overlapping ? nil : NSToolbar(identifier: "VeerAgentPanel") }
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    private func makePanel() -> NSPanel? {
        guard let store, let agent else { return nil }
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        // Read by VoiceOver and the Window menu; the panel shows its own header instead.
        panel.title = String(localized: "Agent 面板")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // The main window's top row is a toolbar's height: the same here keeps the two in line.
        panel.toolbar = NSToolbar(identifier: "VeerAgentPanel")
        panel.toolbarStyle = .unified
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenNone]
        panel.delegate = self
        let host = NSHostingController(rootView: content())
        // The panel's size is this controller's to set, not its content's.
        host.sizingOptions = []
        panel.contentViewController = host
        self.host = host
        return panel
    }

    private func content() -> AnyView {
        guard let store, let agent else { return AnyView(EmptyView()) }
        return AnyView(AgentSideContent().environment(store).environment(agent).tint(.veerAccent)
            .focusedSceneValue(\.sidebar, sidebar))
    }

    // MARK: NSWindowDelegate

    /// ⌘W in the panel closes the panel, not a window the person thinks of as separate.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store?.agentPanel = false
        return false
    }

    /// Text edits and routing changes share the main window's undo stack in either window.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { parent?.undoManager }

    /// Only its width changes, within the panel's range; its height is the main window's.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !placing else { return frameSize }
        let range = AgentPanelColumn.widths
        return NSSize(width: min(max(frameSize.width, range.lowerBound), range.upperBound), height: sender.frame.height)
    }

    func windowDidResize(_ notification: Notification) {
        guard !placing, let panel, panel.inLiveResize else { return }
        store?.agentPanelWidth = panel.frame.width
    }

    /// Back against the main window, whichever edge was dragged.
    func windowDidEndLiveResize(_ notification: Notification) { place() }
}

/// The panel's content, with its top row moving the main window as its title bar does.
private struct AgentSideContent: View {
    var body: some View {
        AgentPanel()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surface)
            .overlay(alignment: .top) {
                WindowDragArea(movesParent: true).frame(height: MainView.topRowHeight).ignoresSafeArea(.container, edges: .top)
            }
    }
}
