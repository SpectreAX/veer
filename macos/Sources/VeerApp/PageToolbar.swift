import SwiftUI
import VeerProxy
import VeerUI

/// What a page puts at the top of the window: controls grouped by what they do, each group in glass
/// of its own.
struct PageToolbarContent {
    let page: Page
    let groups: [AnyView]
}

struct PageToolbarKey: PreferenceKey {
    nonisolated(unsafe) static let defaultValue: PageToolbarContent? = nil
    static func reduce(value: inout PageToolbarContent?, nextValue: () -> PageToolbarContent?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Buttons and a search field for the top row, in place of `.toolbar`, whose items appear and
    /// vanish at once (and whose search item crashed the app; see `ToolbarSearchField`).
    func pageToolbar<Content: View>(_ page: Page, @ViewBuilder content: () -> Content) -> some View {
        preference(key: PageToolbarKey.self, value: PageToolbarContent(page: page, groups: [AnyView(content())]))
    }

    /// Two groups, the most a page has, so that the row keeps to three with the window's own.
    func pageToolbar<First: View, Content: View>(_ page: Page, @ViewBuilder first: () -> First,
                                                 @ViewBuilder content: () -> Content) -> some View {
        preference(key: PageToolbarKey.self, value: PageToolbarContent(page: page, groups: [AnyView(first()), AnyView(content())]))
    }
}

/// The window's top corner: the page's groups, then the window's own, each in glass of its own. The
/// HIG says to group toolbar items by function and to aim for at most three groups, so a page has two
/// and the Agent panel and start and stop, which are always there, share the last at the far end. It
/// stays where it is, and the page's groups spring to their new widths while their controls blur.
struct ToolbarCapsule: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: PageToolbarContent?

    private static let pageSlots = 2

    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    /// Filled from the edge inward, so that a page's last group always sits in the same place.
    private func group(inSlot slot: Int) -> AnyView? {
        guard let groups = content?.groups else { return nil }
        let index = slot - (Self.pageSlots - groups.count)
        return groups.indices.contains(index) ? groups[index] : nil
    }

    var body: some View {
        // One container, as neighbouring glass should be: each samples what is behind it, not the other.
        GlassGroup(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                ForEach(0..<Self.pageSlots, id: \.self) { slot in
                    pageGroup(group(inSlot: slot))
                }
                HStack(spacing: Spacing.xs) {
                    if store.page != .agent {
                        panelToggle.transition(swap)
                    }
                    StartStopButton()
                }
                .padding(.horizontal, Spacing.xs)
                .frame(height: 40)
                .glassSurface(in: Capsule())
            }
            .buttonStyle(ToolbarCapsuleButtonStyle())
            .labelStyle(.iconOnly)
            .labelsHidden()
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: content?.page)
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: store.page)
    }

    /// Always there, at no width without controls: its edge then moves with its neighbour on the
    /// same spring, where a view that fades in sits at its final place and waits.
    private func pageGroup(_ group: AnyView?) -> some View {
        RevealLayout(progress: group == nil ? 0 : 1) {
            if let group, let content {
                HStack(spacing: Spacing.xs) { group }
                    .padding(.horizontal, Spacing.xs)
                    .id(content.page)
                    .transition(swap)
            }
        }
        .frame(height: 40)
        .clipShape(Capsule())
        .glassSurface(in: Capsule())
        // A hairline otherwise: the material before macOS 26 strokes its edge at any width.
        .opacity(group == nil ? 0 : 1)
    }

    private var panelToggle: some View {
        Button { store.agentPanel.toggle() } label: { Label(String(localized: "Agent 面板"), systemImage: "sparkles") }
            .buttonStyle(ToolbarCapsuleButtonStyle(isOn: store.agentPanel))
            .help(store.agentPanel ? String(localized: "隐藏 Agent 面板（⌥⌘I）") : String(localized: "显示 Agent 面板（⌥⌘I）"))
    }
}

/// Its content at its own size against the trailing edge, in `progress` of that width.
private struct RevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: (sizes.map(\.width).max() ?? 0) * progress, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
        }
    }
}

/// A switch in a toolbar group, filled when on. Its state is in the fill and for VoiceOver; `help` adds
/// the detail that a card used to show.
struct ToolbarToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let help: String
    /// In place of on or off, when that is not the whole story.
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(ToolbarCapsuleButtonStyle(isOn: isOn))
            .help(help)
            .accessibilityValue(value ?? (isOn ? String(localized: "已打开") : String(localized: "已关闭")))
            .accessibilityAddTraits(.isToggle)
    }
}

/// A round icon button in a toolbar group: a soft highlight on hover and press, filled when on.
struct ToolbarCapsuleButtonStyle: ButtonStyle {
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(isOn ? Color.onAccent : Color.primary)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: 32, height: 32)
            .background(background(pressed: configuration.isPressed), in: Circle())
            .contentShape(Circle())
            .onHover { hovering = $0 && isEnabled }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: isOn)
    }

    private func background(pressed: Bool) -> Color {
        if isOn { return .accentFill }
        return pressed ? Color.primary.opacity(0.16) : hovering ? Color.primary.opacity(0.08) : .clear
    }
}
