import AppKit
import Foundation

/// Where the Agent shows beside the pages. One `AgentStore` and one conversation whichever it is:
/// moving between them hands the same state to another view and re-sends nothing.
///
/// - `hidden`: neither. A running turn goes on.
/// - `docked`: the panel at the main window's trailing edge (`AgentPanel`).
/// - `detached`: a window of its own (`AgentWindow`). Closing it is `hidden`, not `docked`.
enum AgentPresentation: String, CaseIterable, Sendable {
    case hidden, docked, detached

    /// Saved by this version, or else by one from before the window, which saved only whether the
    /// panel was open. The panel is open on a first launch.
    static func saved(_ raw: String?, panel: Bool?) -> AgentPresentation {
        raw.flatMap(AgentPresentation.init(rawValue:)) ?? (panel ?? true ? .docked : .hidden)
    }

    /// The place the toolbar's button brings back. Never `hidden`, which it would not bring back.
    static func savedLast(_ raw: String?, current: AgentPresentation) -> AgentPresentation {
        if current != .hidden { return current }
        return raw.flatMap(AgentPresentation.init(rawValue:)).flatMap { $0 == .hidden ? nil : $0 } ?? .docked
    }

    /// The toolbar's Agent button: an open window comes forward and stays open; the panel closes;
    /// with neither, the last of the two comes back.
    func toggled(last: AgentPresentation) -> AgentPresentation {
        switch self {
        case .detached: .detached
        case .docked: .hidden
        case .hidden: last == .detached ? .detached : .docked
        }
    }
}

/// Where a conversation is scrolled to, at the granularity a move between the panel and the window
/// can restore: at the newest turn and following it, or at the top of a turn.
struct ScrollSpot: Equatable {
    var session: UUID
    var followsBottom = true
    var topTurnID: UUID?
    var recorded = Date()

    /// Only a move made just now hands it on. Left untaken, by a view that never came, it would
    /// otherwise move a conversation opened much later.
    static let handoffLifetime: TimeInterval = 5
}

extension AgentStore {
    /// The panel's button, or the View menu: the panel closes as it always does, the page takes the
    /// whole width, and the window shows the same conversation. An open window comes forward.
    func detach() {
        handOffScroll()
        proxy.agentPresentation = .detached
        proxy.openAgentWindow()
    }

    /// Back into the main window, opened again if it was closed. The window closes itself when it
    /// sees the change (`AgentWindow`), and the panel opens with its usual motion.
    func dock() {
        handOffScroll()
        proxy.openMainWindow()
        proxy.agentPresentation = .docked
    }

    /// The toolbar's Agent button (`AgentPresentation.toggled`).
    func toggleFromToolbar() {
        let next = proxy.agentPresentation.toggled(last: proxy.lastAgentPresentation)
        if next == .detached { detach() } else { proxy.agentPresentation = next }
    }

    /// Anything that asks for the Agent, such as ⌘N or "Ask Agent": its window if that is where it is or
    /// was last, else the panel. On the Agent page the page is the Agent.
    func showAgent() {
        switch proxy.agentPresentation {
        case .detached: proxy.openAgentWindow()
        case .docked: break
        case .hidden:
            if proxy.lastAgentPresentation == .detached { detach() } else if proxy.page != .agent { proxy.agentPresentation = .docked }
        }
    }

    /// The window was closed, with its close button, ⌘W or the Window menu: hidden, as the panel's
    /// hide button leaves it. Its conversation and anything running are kept.
    func windowClosed() {
        if proxy.agentPresentation == .detached { proxy.agentPresentation = .hidden }
    }

    /// The window opened some other way than `detach`, from the Window menu: it is where the Agent is.
    func windowAppeared() {
        guard proxy.agentPresentation != .detached else { return }
        handOffScroll()
        proxy.agentPresentation = .detached
    }

    /// The conversation on screen now hands where it is scrolled to the view that shows it next.
    func handOffScroll() {
        scrollHandoff = scrollSpot.map { spot in
            var spot = spot
            spot.recorded = .now
            return spot
        }
    }

    /// For the view that shows `session` next, once.
    func takeScrollHandoff(for session: UUID?, now: Date = .now) -> ScrollSpot? {
        defer { scrollHandoff = nil }
        guard let handoff = scrollHandoff, handoff.session == session,
              now.timeIntervalSince(handoff.recorded) < ScrollSpot.handoffLifetime else { return nil }
        return handoff
    }
}

/// Where the Agent's window opens and stays: AppKit's coordinates, origin at the bottom left.
enum AgentWindowPlacement {
    static let defaultSize = CGSize(width: 520, height: 720)
    /// The composer's two rows of controls and hints fit from 360 wide (`AgentWindowTests`), the
    /// panel's narrowest less its margins; 380 leaves the title menu room beside the toolbar's buttons.
    static let minimumSize = CGSize(width: 380, height: 420)
    /// Between the window and the main window, or a screen's edge.
    static let gap: CGFloat = 20

    /// A saved frame, moved and if need be shrunk onto the screen it is most on, or onto `anchor`'s
    /// screen when it is on none now (its display was disconnected). With nothing saved, the default
    /// size beside the main window (`anchor`) on its screen, or over its trailing edge where the
    /// panel was when there is no room beside it.
    static func frame(saved: CGRect?, screens: [CGRect], anchor: CGRect?) -> CGRect? {
        guard let fallback = screens.first else { return nil }
        let anchorScreen = anchor.flatMap { screen(for: $0, in: screens) } ?? fallback
        if let saved, saved.width > 0, saved.height > 0 {
            if let screen = screen(for: saved, in: screens) { return clamp(saved, into: screen) }
            let moved = CGRect(origin: CGPoint(x: anchorScreen.midX - saved.width / 2, y: anchorScreen.midY - saved.height / 2), size: saved.size)
            return clamp(moved, into: anchorScreen)
        }
        let size = defaultSize
        guard let anchor else {
            return clamp(CGRect(origin: CGPoint(x: anchorScreen.midX - size.width / 2, y: anchorScreen.midY - size.height / 2), size: size), into: anchorScreen)
        }
        let top = anchor.maxY - size.height
        let beside = CGRect(origin: CGPoint(x: anchor.maxX + gap, y: top), size: size)
        if beside.minX >= anchorScreen.minX, beside.maxX <= anchorScreen.maxX { return clamp(beside, into: anchorScreen) }
        return clamp(CGRect(origin: CGPoint(x: anchor.maxX - size.width - gap, y: top - gap), size: size), into: anchorScreen)
    }

    /// The screen a frame is most on, if it is on any.
    static func screen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
        let areas = screens.map { screen -> (CGRect, CGFloat) in
            let overlap = screen.intersection(frame)
            return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = areas.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Wholly inside `screen`: no larger than it, and no smaller than the window's minimum unless the
    /// screen is.
    static func clamp(_ frame: CGRect, into screen: CGRect) -> CGRect {
        let width = min(max(frame.width, min(minimumSize.width, screen.width)), screen.width)
        let height = min(max(frame.height, min(minimumSize.height, screen.height)), screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
