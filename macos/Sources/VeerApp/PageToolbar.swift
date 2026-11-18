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
/// stays where it is. On a page switch a group that stays springs to its new width while its controls
/// blur into the new ones, and one that comes or goes fades in or out where it stands, glass and all:
/// the same motion either way.
struct ToolbarCapsule: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    let content: PageToolbarContent?

    private static let pageSlots = 2
    /// The height of each glass capsule in the row, which the title's capsule shares.
    static let height: CGFloat = 40

    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    /// Filled from the edge inward, so that a page's last group always sits in the same place.
    private func group(inSlot slot: Int) -> AnyView? {
        guard let groups = content?.groups else { return nil }
        let index = slot - (Self.pageSlots - groups.count)
        return groups.indices.contains(index) ? groups[index] : nil
    }

    var body: some View {
        // One container, as neighbouring glass should be: it lets a group's glass merge into the next.
        GlassGroup(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                ForEach(0..<Self.pageSlots, id: \.self) { slot in
                    if let group = group(inSlot: slot), let content {
                        pageGroup(group, page: content.page, slot: slot)
                    }
                }
                HStack(spacing: Spacing.xs) {
                    if store.page != .agent {
                        panelToggle.transition(swap)
                    }
                    StartStopButton()
                }
                .padding(.horizontal, Spacing.xs)
                .frame(height: Self.height)
                .glassSurface(in: Capsule(), id: "window", namespace: glass)
            }
            .buttonStyle(ToolbarCapsuleButtonStyle())
            .labelStyle(.iconOnly)
            .labelsHidden()
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: content?.page)
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: store.page)
    }

    /// The glass stays while its page's controls change, so only they blur; the glass comes and goes
    /// with the group itself.
    private func pageGroup(_ group: AnyView, page: Page, slot: Int) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: Spacing.xs) { group }
                .padding(.horizontal, Spacing.xs)
                .id(page)
                .transition(swap)
        }
        .frame(height: Self.height)
        .clipShape(Capsule())
        .glassSurface(in: Capsule(), id: slot, namespace: glass)
        .transition(swap)
    }

    private var panelToggle: some View {
        Button { store.agentPanel.toggle() } label: { Label(String(localized: "Agent 面板"), systemImage: "sparkles") }
            .buttonStyle(ToolbarCapsuleButtonStyle(isOn: store.agentPanel))
            .help(store.agentPanel ? String(localized: "隐藏 Agent 面板（⌥⌘I）") : String(localized: "显示 Agent 面板（⌥⌘I）"))
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
