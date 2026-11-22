import AppKit
import SwiftUI
import VeerProxy

/// The Agent in a standard window of its own: the panel's conversation, from the same `AgentStore`,
/// with the window's toolbar in place of the panel's header. It closes itself when the Agent goes
/// back into the main window, and closing it hides the Agent (`AgentPresentation`).
struct AgentWindow: View {
    static let id = "agent"

    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("agentWindowOnTop") private var onTop = false
    /// Off in snapshots, which draw it in a window of their own and must not save its frame.
    var managesWindow = true
    /// SwiftUI keeps a closed window and its views; without this its conversation would go on
    /// following the store unseen. Nothing is built while it is closed.
    @State private var isOpen = false

    var body: some View {
        Group {
            if isOpen { window } else { Color.clear }
        }
        .onAppear {
            isOpen = true
            guard managesWindow else { return }
            agent.windowAppeared()
            DockPresence.windowOpened()
        }
        .onDisappear {
            isOpen = false
            guard managesWindow else { return }
            agent.windowClosed()
            DockPresence.windowClosed()
        }
        .onChange(of: proxy.agentPresentation) { _, presentation in
            if managesWindow, presentation != .detached { dismissWindow(id: Self.id) }
        }
    }

    private var window: some View {
        content
            .environment(\.agentCompact, true)
            .frame(minWidth: AgentWindowPlacement.minimumSize.width, maxWidth: .infinity,
                   minHeight: AgentWindowPlacement.minimumSize.height, maxHeight: .infinity)
            // The window's name in the Window menu and for VoiceOver. The toolbar shows it as the menu of
            // recent conversations, as the panel's header does (`AgentWindowBridge` hides the plain title).
            .navigationTitle(agent.current?.title ?? String(localized: "Agent"))
            .toolbar { toolbar }
            // The sheets its turns raise: the group editor and what was sent to the AI. The main window
            // raises them while the Agent is in it.
            .agentPresentations(agent, scope: .conversation)
            .background(AgentWindowBridge(onTop: onTop, managesFrame: managesWindow))
    }

    private var showsSuggestion: Bool { proxy.page != .overview && !proxy.suggestions.isEmpty }

    /// The conversation under the window's toolbar, which from macOS 26 softens what scrolls under it.
    /// No container of glass around it: the window's own background, corners and shadow are the
    /// frame. A suggestion goes above it, as on the Agent page: a bar of the system's over the
    /// conversation would draw its separator line whenever it was empty.
    private var content: some View {
        VStack(spacing: 0) {
            if showsSuggestion {
                SuggestionCards(limit: 1).padding(Spacing.md)
                Divider()
            }
            AgentConversation()
        }
    }

    @ViewBuilder private var conversations: some View {
        ForEach(agent.sessions.prefix(AgentPanel.recentCount)) { session in
            Toggle(session.title, isOn: Binding(get: { agent.selectedID == session.id }, set: { if $0 { agent.select(session.id) } }))
        }
        if agent.sessions.count > AgentPanel.recentCount {
            Divider()
            Button(String(localized: "全部对话…")) { proxy.showPage(.agent) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // `toolbarTitleMenu` shows no menu on a Mac window that is not a document's.
        ToolbarItem(placement: .navigation) {
            Menu { conversations } label: {
                Label(agent.current?.title ?? String(localized: "Agent"), systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 240)
            .disabled(agent.sessions.isEmpty)
            .help(String(localized: "切换对话"))
            .accessibilityLabel(String(localized: "切换对话"))
            // Which conversation is open, which the label alone would not say.
            .accessibilityValue(agent.current?.title ?? "")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            UndoChangeButton()
            Button { agent.newThread() } label: { Label(String(localized: "新对话"), systemImage: "square.and.pencil") }
                .help(String(localized: "新对话（⌘N）"))
                .disabled(proxy.activeProfile == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { agent.dock() } label: { Label(String(localized: "停靠至主窗口"), systemImage: "rectangle.righthalf.inset.filled") }
                .help(String(localized: "停靠至主窗口"))
        }
    }
}

extension ProxyStore {
    /// A page of the main window, from the Agent's window too, which brings the main window forward.
    func showPage(_ page: Page) {
        self.page = page
        if agentPresentation == .detached { openMainWindow() }
    }
}

/// AppKit, for what a SwiftUI `Window` scene does not offer on macOS 14: where it first opens
/// (`defaultWindowPlacement` needs macOS 15), its frame kept and put back on a screen after a display
/// goes, Always on Top (`NSWindow.level`), and staying out of the main window's tabs and of state
/// restoration, which would reopen it at launch with the Agent elsewhere.
struct AgentWindowBridge: NSViewRepresentable {
    var onTop: Bool
    var managesFrame: Bool

    static let frameKey = "agentWindowFrame"

    final class Host: NSView {
        var onTop = false { didSet { if onTop != oldValue { applyLevel() } } }
        var managesFrame = true
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            configureBehavior(window)
            // Again once SwiftUI has finished setting the window up, which resets its collection behavior.
            DispatchQueue.main.async { [weak self, weak window] in if let window { self?.configureBehavior(window) } }
            guard managesFrame else { return }
            place(window)
            let center = NotificationCenter.default
            center.removeObserver(self)
            center.addObserver(self, selector: #selector(save), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(save), name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }

        private func configureBehavior(_ window: NSWindow) {
            // The toolbar's title menu says it; the title stays set for the Window menu and VoiceOver.
            window.titleVisibility = .hidden
            window.isRestorable = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            applyLevel()
        }

        private func applyLevel() {
            window?.level = onTop ? .floating : .normal
        }

        private func place(_ window: NSWindow) {
            let saved = UserDefaults.standard.string(forKey: AgentWindowBridge.frameKey).map(NSRectFromString)
            let main = NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.hasPrefix("main") == true }
                ?? NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }
            guard let frame = AgentWindowPlacement.frame(saved: saved, screens: NSScreen.screens.map(\.visibleFrame), anchor: main?.frame) else { return }
            window.setFrame(frame, display: false)
        }

        @objc private func save() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: AgentWindowBridge.frameKey)
        }

        /// A display was disconnected or rearranged: back wholly onto a screen.
        @objc private func screensChanged() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let frame = AgentWindowPlacement.frame(saved: window.frame, screens: NSScreen.screens.map(\.visibleFrame), anchor: nil),
                  frame != window.frame else { return }
            window.setFrame(frame, display: true)
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.onTop = onTop
        host.managesFrame = managesFrame
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.managesFrame = managesFrame
        host.onTop = onTop
    }

    static func dismantleNSView(_ host: Host, coordinator: ()) {
        NotificationCenter.default.removeObserver(host)
    }
}
