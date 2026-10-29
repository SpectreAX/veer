import AppKit
import SwiftUI

@main
struct VeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppDelegate.store

    var body: some Scene {
        Window("Veer", id: "main") {
            MainView()
                .environment(store)
                .tint(.veerAccent)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .commands { VeerCommands(store: store) }

        MenuBarExtra {
            MenuBarContent().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }

        Settings {
            SettingsView().environment(store).tint(.veerAccent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = ProxyStore()
    /// Opens the main window; set by the menu bar label, which can reach `openWindow`.
    static var openMain: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read now: a static is set on first use, which would otherwise be after a change.
        _ = AppLanguage.launched
        if let directory = ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] {
            SnapshotRunner.run(into: URL(fileURLWithPath: directory))
            return
        }
        Self.store.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.store.shutdown()
    }

    /// Closing the window keeps the proxy running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMain?() }
        return true
    }
}

/// Veer lives in the menu bar: it shows in the Dock and ⌘-Tab only while its window is open.
enum DockPresence {
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        // After the window has gone, so the switch does not deactivate the closing window.
        Task { @MainActor in
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct VeerCommands: Commands {
    let store: ProxyStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("导入配置…") { store.openImport() }.keyboardShortcut("o")
            Button("用剪贴板内容导入…") { store.openImport(prefill: NSPasteboard.general.string(forType: .string) ?? "") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("导出配置…") { if let profile = store.activeProfile { ConfigExport.run(profile, store: store) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.activeProfile == nil)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { store.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
        }
        CommandMenu("代理") {
            Button(store.isRunning ? String(localized: "停止") : String(localized: "启动")) { store.isRunning ? store.stop() : store.start() }
                .keyboardShortcut("r")
                .disabled(store.activeProfile == nil || store.phase == .starting)
            Toggle("系统代理", isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!store.isRunning)
            Divider()
            Picker("模式", selection: Binding(get: { store.mode }, set: { store.setMode($0) })) {
                ForEach(ProxyStore.Mode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!store.isRunning)
        }
    }
}
