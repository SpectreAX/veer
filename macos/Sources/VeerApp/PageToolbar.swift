import SwiftUI
import VeerProxy
import VeerUI

/// What a page puts in the capsule at the top of the window.
struct PageToolbarContent {
    let page: Page
    let view: AnyView
    /// Stands apart from the capsule, on its left, in glass of its own.
    var standalone: AnyView?
}

struct PageToolbarKey: PreferenceKey {
    nonisolated(unsafe) static let defaultValue: PageToolbarContent? = nil
    static func reduce(value: inout PageToolbarContent?, nextValue: () -> PageToolbarContent?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Buttons and a search field for the capsule, in place of `.toolbar`, whose items appear and
    /// vanish at once (and whose search item crashed the app; see `ToolbarSearchField`).
    func pageToolbar<Content: View>(_ page: Page, @ViewBuilder content: () -> Content) -> some View {
        preference(key: PageToolbarKey.self, value: PageToolbarContent(page: page, view: AnyView(content())))
    }

    /// The same, with a control that stands apart from the capsule, such as a switch between views.
    func pageToolbar<Standalone: View, Content: View>(_ page: Page, @ViewBuilder standalone: () -> Standalone,
                                                      @ViewBuilder content: () -> Content) -> some View {
        preference(key: PageToolbarKey.self,
                   value: PageToolbarContent(page: page, view: AnyView(content()), standalone: AnyView(standalone())))
    }
}

/// A glass capsule in the window's top corner, whose width springs from page to page while the
/// page's controls blur in and out. Start and stop and the Agent panel sit at its far end, so they
/// stay where they are as the rest changes.
struct ToolbarCapsule: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: PageToolbarContent?

    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    var body: some View {
        // One group, as neighbouring glass should be: each samples what is behind it, not the other.
        GlassGroup(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                // Always there, at no width without a control: its edge then moves with the capsule
                // on the same spring, where a view that fades in sits at its final place and waits.
                RevealLayout(progress: content?.standalone == nil ? 0 : 1) {
                    if let content, let standalone = content.standalone {
                        standalone
                            .id(content.page)
                            .transition(swap)
                    }
                }
                .clipped()
                .frame(height: 40)
                .glassSurface(in: Capsule())
                HStack(spacing: Spacing.xs) {
                    if let content {
                        HStack(spacing: Spacing.xs) { content.view }
                            .id(content.page)
                            .transition(swap)
                    }
                    if store.page != .agent {
                        panelToggle.transition(swap)
                    }
                    StartStopButton()
                }
                .buttonStyle(ToolbarCapsuleButtonStyle())
                .labelStyle(.iconOnly)
                .labelsHidden()
                .padding(.horizontal, Spacing.xs)
                .frame(height: 40)
                .glassSurface(in: Capsule())
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: content?.page)
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: store.page)
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

/// A switch in the capsule, filled when on. Its state is in the fill and for VoiceOver; `help` adds
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

/// A round icon button in the capsule: a soft highlight on hover and press, filled when on.
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
        if isOn { return .veerAccent }
        return pressed ? Color.primary.opacity(0.16) : hovering ? Color.primary.opacity(0.08) : .clear
    }
}
