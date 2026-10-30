import SwiftUI
import VeerProxy
import VeerUI

/// What a page puts in the capsule at the top of the window.
struct PageToolbarContent {
    let page: Page
    let view: AnyView
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
}

/// A glass capsule in the window's top corner, whose width springs from page to page while the
/// page's controls blur in and out. Start and stop and the Agent panel sit at its far end, so they
/// stay where they are as the rest changes.
struct ToolbarCapsule: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: PageToolbarContent?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let content {
                HStack(spacing: Spacing.xs) { content.view }
                    .id(content.page)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
            if store.page != .agent {
                panelToggle.transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
            StartStopButton()
        }
        .buttonStyle(ToolbarCapsuleButtonStyle())
        .labelStyle(.iconOnly)
        .labelsHidden()
        .padding(.horizontal, Spacing.xs)
        .frame(height: 40)
        .glassSurface(in: Capsule())
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: content?.page)
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.14), value: store.page)
    }

    private var panelToggle: some View {
        Button { store.agentPanel.toggle() } label: { Label(String(localized: "Agent 面板"), systemImage: "sparkles") }
            .buttonStyle(ToolbarCapsuleButtonStyle(isOn: store.agentPanel))
            .help(store.agentPanel ? String(localized: "隐藏 Agent 面板（⌥⌘I）") : String(localized: "显示 Agent 面板（⌥⌘I）"))
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
            .foregroundStyle(isOn ? Color.white : Color.primary)
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
