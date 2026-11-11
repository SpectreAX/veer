import SwiftUI
import VeerCore
import VeerProxy

struct ConversationView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.agentCompact) private var compact
    @State private var followsBottom = true

    static let examples = [String(localized: "Netflix 走日本，ChatGPT 走美国"), String(localized: "YouTube 走香港"), String(localized: "example.com 直连"), String(localized: "屏蔽广告")]

    var body: some View {
        let allTurns = store.current?.turns ?? []
        let turns = allTurns.suffix(store.visibleTurnCount)
        let hidden = allTurns.count - turns.count
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: only the newest page of turns is shown, and a lazy stack that opens at the
                // bottom while the window is still settling at launch never creates its rows, which left
                // the first session blank until another one was selected.
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if turns.isEmpty && !store.isArchived { emptyState }
                    if hidden > 0, let first = turns.first?.id {
                        Button {
                            followsBottom = false
                            store.olderTurnPages += 1
                            // Keep the turn that was at the top in place instead of jumping to the oldest.
                            DispatchQueue.main.async { proxy.scrollTo(first, anchor: .top) }
                        } label: {
                            Label(String(localized: "显示更早的 \(min(AgentStore.turnPage, hidden)) 轮对话（还有 \(hidden) 轮）"), systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(Color.veerAccent)
                        .frame(maxWidth: .infinity)
                        .help(String(localized: "较早的对话不会自动显示，以便快速切换对话"))
                    }
                    ForEach(turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, compact ? Spacing.md : Spacing.xl)
                .padding(.top, compact ? Spacing.lg : Spacing.xl)
                .padding(.bottom, Spacing.lg)
                .frame(maxWidth: Metrics.readingWidth)
                .frame(maxWidth: .infinity)
            }
            // A scroll view per session, opening at the newest turn. Reusing one kept the previous
            // session's scroll position, which can lie past the end of a shorter session's content
            // and left the conversation blank.
            .defaultScrollAnchor(.bottom)
            .modifier(BottomFollowing(followsBottom: $followsBottom, proxy: proxy))
            // After the geometry tracking, so a new session's scroll view is not compared with the
            // previous one's position.
            .id(store.selectedID)
            .onChange(of: store.conversationToken) {
                if followsBottom { withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: allTurns.count) { old, new in
                // A new turn is always something the user just asked for: show it.
                guard new > old else { return }
                followsBottom = true
                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selectedID) { followsBottom = true }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .frame(maxWidth: Metrics.readingWidth)
                    // Floats just above the composer without taking layout space: if it changed the
                    // inset, its own appearance would move the view off the bottom and keep it shown.
                    .overlay(alignment: .top) {
                        if !followsBottom && !turns.isEmpty {
                            Button {
                                followsBottom = true
                                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                            } label: {
                                Label(String(localized: "回到最新"), systemImage: "arrow.down")
                            }
                            .secondaryAction()
                            .controlSize(.small)
                            .help(String(localized: "滚动到最新一轮"))
                            .fixedSize()
                            .offset(y: -(Spacing.xxl + Spacing.xs))
                            .transition(.opacity)
                        }
                    }
                .padding(.horizontal, compact ? Spacing.md : Spacing.xl)
                .padding(.bottom, Spacing.md)
                .padding(.top, Spacing.sm)
                .background {
                    LinearGradient(stops: [.init(color: Color.surface.opacity(0), location: 0), .init(color: Color.surface, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
            }
        }
        .background(Color.surface)
    }

    /// An archived conversation can be read but not continued, so it says why in the composer's place.
    @ViewBuilder private var composer: some View {
        if store.isArchived { ArchivedNotice() } else { ComposerView() }
    }

    /// Within 40 pt of the end, or everything fits. The visible area runs under the toolbar and the
    /// composer, so at the very bottom it ends at the content height plus the bottom inset; leaving
    /// the insets out made the newest turn count as "not at the bottom" and kept "回到最新" showing.
    @available(macOS 15, *)
    static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
            || geometry.contentSize.height <= geometry.containerSize.height + 1
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "想怎么分流？")).font(.title2.weight(.semibold))
                Text(String(localized: "用自然语言描述，例如某个服务走哪个出口。Veer 会生成修改，等你确认后应用，运行中的内核立即生效。"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: Spacing.sm) {
                ForEach(Self.examples, id: \.self) { example in
                    Chip(text: example, symbol: "text.bubble") { store.send(example) }
                }
            }
            if !store.effectiveUseAI {
                StatusBadge(kind: .info, text: String(localized: "当前使用本地解析：支持常见服务、域名、地区与 @ 出口。需要更灵活的说法时，可在设置中配置 AI。"), compact: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Spacing.xxl)
    }
}

/// Keeps the newest turn in view while the user is following it. Needs macOS 15's scroll
/// geometry; before it the conversation only jumps to new turns.
private struct BottomFollowing: ViewModifier {
    @Binding var followsBottom: Bool
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            tracked(content.scrollEdgeEffectStyle(.soft, for: .bottom))
        } else if #available(macOS 15, *) {
            tracked(content)
        } else {
            content
        }
    }

    @available(macOS 15, *)
    private func tracked(_ content: some View) -> some View {
        content
            .onScrollGeometryChange(for: BottomTracking.self) { geometry in
                BottomTracking(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
                               atBottom: ConversationView.isAtBottom(geometry))
            } action: { old, new in
                // Reaching the bottom by any means means following the newest turn again.
                if new.atBottom { followsBottom = true }
                // Content grew or the window was resized: stay on the newest turn if following it.
                let resized = old.contentHeight != new.contentHeight || old.containerHeight != new.containerHeight
                if followsBottom && resized { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onScrollPhaseChange { old, new, context in
                // The user finished scrolling: follow again only if they ended at the bottom.
                guard new == .idle, [.interacting, .decelerating, .tracking].contains(old) else { return }
                followsBottom = ConversationView.isAtBottom(context.geometry)
            }
    }
}

private struct BottomTracking: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var atBottom: Bool
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat
    /// Which side each row starts from.
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var x = bounds.minX
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; rows.append([]) }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let width = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            var x = alignment == .trailing ? bounds.maxX - width : bounds.minX
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

/// In place of the composer when the conversation's profile was deleted: its changes would have
/// nowhere to go, so it stays to read, and a new conversation is one click away.
private struct ArchivedNotice: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "archivebox").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "对话已归档")).font(.headline)
                Text(String(localized: "它所属的配置已删除，只能查看记录。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.sm)
            Button(String(localized: "新对话")) { agent.newThread() }
                .secondaryAction()
                .help(String(localized: "在正在使用的配置上开始新对话（⌘N）"))
                .disabled(proxy.activeProfile == nil)
        }
        .panel(padding: Spacing.md)
    }
}
