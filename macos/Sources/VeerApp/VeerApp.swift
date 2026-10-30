import AppKit
import SwiftUI

@main
struct VeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppDelegate.store
    @State private var agent = AppDelegate.agent

    var body: some Scene {
        Window("Veer", id: "main") {
            MainView()
                .environment(store)
                .environment(agent)
                .tint(.veerAccent)
                .frame(minWidth: 860, minHeight: 560)
        }
        // The window's title is `MainView`'s own, in the row with its other controls.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .commands { VeerCommands(store: store, agent: agent) }

        MenuBarExtra {
            MenuBarContent().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }

        Settings {
            SettingsView().environment(store).environment(agent).tint(.veerAccent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = ProxyStore()
    static let agent = AgentStore(proxy: store)
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
        Updater.shared.start()
        HotKeyCenter.shared.perform = Self.perform
        HotKeyCenter.shared.start()
    }

    /// A global shortcut, pressed in any app.
    static func perform(_ action: HotKeyAction) {
        switch action {
        case .toggleProxy:
            if store.isRunning { store.setSystemProxy(!store.systemProxyOn) } else { store.startWithSystemProxy() }
        case .switchMode:
            guard store.isRunning else { return }
            let modes = ProxyStore.Mode.allCases
            store.setMode(modes[(modes.firstIndex(of: store.mode)! + 1) % modes.count])
        case .openWindow:
            openMain?()
            DockPresence.windowOpened()
        case .newThread:
            openMain?()
            DockPresence.windowOpened()
            agent.open(fresh: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.agent.flush()
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
    let agent: AgentStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { Updater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("新对话") { agent.open(fresh: true) }
                .keyboardShortcut("n")
            Divider()
            Button("导入配置…") { store.openImport() }.keyboardShortcut("o")
            Button("用剪贴板内容导入…") { store.openImport(prefill: NSPasteboard.general.string(forType: .string) ?? "") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("导出配置…") { if let profile = store.activeProfile { ConfigExport.run(profile, store: store) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.activeProfile == nil)
            Divider()
            Button("备份…") { BackupFlow.backUp(store: store) }
            Button("从备份恢复…") { BackupFlow.restore(store: store) }
        }
        // In place of the default Find menu, which takes ⌘F first and has nothing to do here.
        CommandGroup(replacing: .textEditing) {
            Button("查找") { ToolbarSearchFocus.focus() }
                .keyboardShortcut("f")
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { store.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Toggle("Agent 面板", isOn: Binding(get: { store.agentPanel }, set: { store.agentPanel = $0 }))
                .keyboardShortcut("i", modifiers: [.command, .option])
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
