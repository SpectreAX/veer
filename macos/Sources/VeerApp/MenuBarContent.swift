import SwiftUI
import VeerProxy

/// The menu bar icon: dimmed while the core is stopped, with the speeds beside it when asked.
struct MenuBarLabel: View {
    let store: ProxyStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Veer's own mark, a template the system tints; dimmed while the core is not running.
            Image(nsImage: MenuBarMark.image)
                .opacity(store.isRunning ? 1 : 0.5)
            if store.showRateInMenuBar, store.isRunning {
                Text(verbatim: "↑\(Format.rate(store.uploadRate)) ↓\(Format.rate(store.downloadRate))")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(store.isRunning ? String(localized: "Veer 运行中") : String(localized: "Veer 已停止"))
        .task { AppDelegate.openMain = { openWindow(id: "main") } }
    }
}

/// Status, the switches people reach for most, and a way into the window.
struct MenuBarContent: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if store.isRunning {
            Text(verbatim: "↑ \(Format.rate(store.uploadRate))  ↓ \(Format.rate(store.downloadRate))")
        }
        Divider()
        Button(store.isRunning ? String(localized: "停止") : String(localized: "启动")) { store.isRunning ? store.stop() : store.start() }
            .disabled(store.activeProfile == nil || store.phase == .starting)
        Toggle("系统代理", isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
            .disabled(!store.isRunning)
        Toggle("TUN", isOn: Binding(get: { store.settings.tun }, set: { store.setTUN($0) }))
        Picker("模式", selection: Binding(get: { store.mode }, set: { store.setMode($0) })) {
            ForEach(ProxyStore.Mode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!store.isRunning)
        if let group = store.mainGroup {
            Menu {
                NodeMenuItems(group: group)
            } label: {
                Text(verbatim: "\(group.name)：\(group.now ?? "—")")
            }
        }
        if store.profiles.count > 1 {
            Picker("使用的配置", selection: Binding(get: { store.activeProfileID }, set: { if let id = $0 { store.activate(id) } })) {
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        Divider()
        Button("打开 Veer") {
            openWindow(id: "main")
            DockPresence.windowOpened()
        }
        Button("退出 Veer") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let profile = store.activeProfile else { return String(localized: "还没有配置") }
        return "\(store.phase.title) · \(profile.name)"
    }
}
