import AppKit
import SwiftUI
import VeerProxy

/// The Agent beside every page but its own: the current conversation and its composer, with
/// the recent conversations in a menu and a way out to the full page.
struct AgentPanel: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy

    /// Conversations listed in the title menu; the rest are on the Agent page.
    static let recentCount = 12
    static let headerHeight: CGFloat = 36

    var body: some View {
        Group {
            if ScrollEdge.available {
                // The header is a bar over the conversation, which scrolls under it with the system's
                // soft edge in place of a line.
                AgentConversation()
                    .softScrollEdge(.top)
                    .scrollEdgeBar(edge: .top, spacing: 0) {
                        // The header, and a suggestion when there is one, on one glass shape, as the
                        // composer is at the bottom. Where a bar's edge is not glass, the system draws
                        // its separator line across the panel's full width, whatever the scroll edge
                        // style: under a plain header, and under a suggestion card on its own. The card
                        // keeps its own fill inside the glass. Alone, the header's shape is a capsule.
                        VStack(spacing: 0) {
                            header
                            suggestion
                        }
                        .glassSurface(in: RoundedRectangle(cornerRadius: Self.headerHeight / 2, style: .continuous))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.top, Spacing.sm)
                    }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    suggestion
                    if showsSuggestion { Divider() }
                    AgentConversation()
                }
            }
        }
        .environment(\.agentCompact, true)
    }

    /// The overview lists every suggestion itself.
    private var showsSuggestion: Bool { proxy.page != .overview && !proxy.suggestions.isEmpty }

    @ViewBuilder private var suggestion: some View {
        if showsSuggestion {
            if ScrollEdge.available {
                // Inside the header's glass, clear of its rounded corners.
                SuggestionCards(limit: 1).padding([.horizontal, .bottom], Spacing.sm)
            } else {
                SuggestionCards(limit: 1).padding(Spacing.md)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Menu {
                ForEach(agent.sessions.prefix(Self.recentCount)) { session in
                    Toggle(session.title, isOn: Binding(get: { agent.selectedID == session.id }, set: { if $0 { agent.select(session.id) } }))
                }
                if agent.sessions.count > Self.recentCount {
                    Divider()
                    Button(String(localized: "全部对话…")) { proxy.page = .agent }
                }
            } label: {
                Label(agent.current?.title ?? String(localized: "Agent"), systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            // A title, not an action: the green stays on the small areas that are.
            .tint(.primary)
            .disabled(agent.sessions.isEmpty)
            .help(String(localized: "切换对话"))
            .accessibilityLabel(String(localized: "切换对话"))
            // Which conversation is open, which the label alone would not say.
            .accessibilityValue(agent.current?.title ?? "")
            Spacer(minLength: Spacing.sm)
            Group {
                Button { agent.undo() } label: { Label(String(localized: "撤销修改"), systemImage: "arrow.uturn.backward") }
                    .help(String(localized: "撤销这个对话里最近应用的修改"))
                    .disabled(!agent.canUndo)
                Button { agent.newThread() } label: { Label(String(localized: "新对话"), systemImage: "square.and.pencil") }
                    .help(String(localized: "新对话（⌘N）"))
                    .disabled(proxy.activeProfile == nil)
                Button { proxy.page = .agent } label: { Label(String(localized: "在 Agent 页打开"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help(String(localized: "在 Agent 页打开，查看全部对话"))
                // The same conversation in a window of its own; the panel closes as it always does.
                Button { agent.detach() } label: { Label(String(localized: "在独立窗口中打开"), systemImage: "macwindow.on.rectangle") }
                    .help(String(localized: "在独立窗口中打开"))
                // Over a window near the screen's edge the toolbar's own switch can be covered.
                Button { proxy.agentPanel = false } label: { Label(String(localized: "隐藏 Agent 面板"), systemImage: "sidebar.trailing") }
                    .help(String(localized: "隐藏 Agent 面板（⌥⌘I）"))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: Self.headerHeight)
    }
}

/// The panel as a column beside the page: a floating glass surface of its own, clear of the
/// window's edges and of the page, its left edge dragged to resize it. Everything in it, the
/// header, conversation and composer, is inside the one shape, which moves as one piece. It stays
/// a floating panel on every system, whatever the system's own sidebars do: it is a helper beside
/// the page, not the window's navigation.
struct AgentPanelColumn: View {
    /// The window's width less the sidebar's: what the page and the panel share.
    var room: CGFloat = .infinity
    @Environment(ProxyStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var widthAtDragStart: Double?

    nonisolated static let idealWidth = 380.0
    nonisolated static let widths = 320.0...520.0
    /// The page's width in the smallest window beside the widest sidebar and the narrowest panel
    /// (860 - 260 - 320), where every page is known to fit. The panel narrows to leave it this.
    nonisolated static let minimumPageWidth: CGFloat = 280
    /// Beyond this room no panel width is narrowed, so the window's width need not be followed.
    nonisolated static let widestRoom = minimumPageWidth + widths.upperBound + chrome
    /// Between the container and the page, the window's trailing edge and its bottom edge.
    nonisolated static let margin: CGFloat = Spacing.sm
    /// What the column takes beside the container: the margin on either side of it.
    nonisolated static let chrome: CGFloat = 2 * margin

    /// The panel's width: the saved one, narrowed so the page keeps `minimumPageWidth`, but never
    /// below the narrowest panel. Without it, in a small window, the page was cut off at its edge.
    nonisolated static func fittedWidth(saved: Double, room: CGFloat) -> CGFloat {
        let resting = widths.contains(saved) ? saved : idealWidth
        return min(resting, max(widths.lowerBound, room - minimumPageWidth - chrome))
    }

    /// The whole column: the container's width and the margin on either side, so the layout that
    /// moves the panel and narrows the page accounts for both from the first frame.
    static func width(_ store: ProxyStore, room: CGFloat) -> CGFloat {
        fittedWidth(saved: store.agentPanelWidth, room: room) + chrome
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        AgentPanel()
            .frame(width: Self.fittedWidth(saved: store.agentPanelWidth, room: room))
            // What scrolls stays inside the corners. Before the surface, so that the glass is not
            // clipped by a shape of ours and keeps the edge the system gives it.
            .clipShape(shape)
            // One floating surface for the header, the conversation and the composer: Liquid Glass
            // from macOS 26 on, the regular material with a hairline before it. No fill, edge or
            // shadow of ours on top of the glass: the system draws its own. The surface is this
            // view's background, so the transform that pushes the panel in moves both as one.
            .glassSurface(in: shape)
            .overlay {
                // Increase Contrast asks for edges that can be told apart.
                if contrast == .increased { shape.strokeBorder(Color.separatorLine).allowsHitTesting(false) }
            }
            .overlay(alignment: .leading) { resizeEdge }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, Self.margin)
    }

    private var resizeEdge: some View {
            Color.clear
                .frame(width: Spacing.sm)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        // From the width shown, which a small window may have narrowed.
                        let start = widthAtDragStart ?? Double(Self.fittedWidth(saved: store.agentPanelWidth, room: room))
                        widthAtDragStart = start
                        store.agentPanelWidth = min(max(start - drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil })
                .accessibilityHidden(true)
    }
}
