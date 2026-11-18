import SwiftUI
import VeerCore
import VeerProxy

struct ConversationView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.agentCompact) private var compact
    @State private var followsBottom = true
    /// The composer's bar, for placing the button back to the newest turn above it.
    @State private var barHeight: CGFloat = 0
    /// The composer's top, for softening what goes under it (`SoftenedUnderComposer`).
    @State private var composerTop: CGFloat?

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
                .environment(\.composerEdge, softensUnderComposer ? composerTop : nil)
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
            .modifier(ComposerBar(asBar: compact) { composerBar })
            .overlay(alignment: .bottom) { backToLatest(turns: turns, proxy: proxy) }
            .coordinateSpace(.named(SoftenedUnderComposer.space))
        }
        .background(background)
    }

    /// In the panel from macOS 26, nothing: the panel's glass is the one base under the header, the
    /// conversation and the composer. A color of the conversation's own was a second base, whose
    /// tone stopped where the bars began. Before macOS 26 the panel is a material, and the
    /// conversation keeps the page's color, which its fade under the composer blends into.
    /// Where the conversation scrolls on under the composer's glass: the panel's system bar, from
    /// macOS 26. Elsewhere it ends above the composer, or fades out under a fade of its own.
    private var softensUnderComposer: Bool { ScrollEdge.available && compact }

    private var background: Color { ScrollEdge.available && compact ? .clear : .surface }

    /// The composer, at the bottom of the conversation. In the panel its 12 pt margins keep the
    /// glass close enough to the bar's sides that the system shows no separator (see `ComposerBar`).
    private var composerBar: some View {
        composer
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(SoftenedUnderComposer.space)).minY } action: { composerTop = $0 }
            .frame(maxWidth: Metrics.readingWidth)
            .padding(.horizontal, compact ? Spacing.md : Spacing.xl)
            .padding(.bottom, Spacing.md)
            .padding(.top, Spacing.sm)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    /// Back to the newest turn, just above the composer. Over the conversation rather than in the
    /// composer's bar: anything drawn in the bar beyond its edge made the system show its separator
    /// line across the panel there (as soon as the composer had grown past one line), and it would
    /// change the bar's height as it came and went. Placed from the bar's measured height, so it
    /// moves up as the composer grows.
    @ViewBuilder private func backToLatest(turns: ArraySlice<Turn>, proxy: ScrollViewProxy) -> some View {
        if !followsBottom && !turns.isEmpty {
            Button {
                followsBottom = true
                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            } label: {
                Image(systemName: "arrow.down").fontWeight(.semibold)
            }
            .secondaryAction()
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help(String(localized: "滚动到最新一轮"))
            .accessibilityLabel(String(localized: "回到最新"))
            .padding(.bottom, barHeight + Spacing.xs)
            .transition(.opacity)
        }
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
        if #available(macOS 15, *) {
            tracked(content.softScrollEdge([.top, .bottom]))
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

/// Puts the composer at the bottom of the conversation.
///
/// In the panel from macOS 26 it is a bar the system knows about: the conversation scrolls on under
/// it and fades softly into it, as under the header, and the composer's glass blurs what passes
/// behind it. The system draws a separator line across the full width at a bar's edge unless the
/// bar's glass reaches close to its sides; in the panel the composer always spans it less 12 pt.
///
/// On the Agent page the composer stops at the reading width, so in a wide window it leaves wide
/// margins and the separator would show; there it sits in a plain inset over a fade of the page's
/// own color, which is the conversation's background, so the fade has no edge. So it does before
/// macOS 26, where there is no scroll edge effect.
private struct ComposerBar<Bar: View>: ViewModifier {
    let asBar: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if ScrollEdge.available, asBar {
            content.scrollEdgeBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                bar().background {
                    LinearGradient(stops: [.init(color: Color.surface.opacity(0), location: 0), .init(color: Color.surface, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
            }
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

    /// No alignment guides of its own: the default placed every subview again to find them.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

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
