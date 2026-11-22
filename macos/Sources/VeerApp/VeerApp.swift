import AppKit
import SwiftUI
import VeerCore

@main
struct VeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppDelegate.store
    @State private var agent = AppDelegate.agent
    @State private var sidebar = SidebarAnimator()

    var body: some Scene {
        Window("Veer", id: "main") {
            MainView(sidebarAnimator: sidebar)
                .environment(store)
                .environment(agent)
                .tint(.veerAccent)
                .frame(minWidth: Metrics.minWindow.width, minHeight: Metrics.minWindow.height)
        }
        // The window's title is `MainView`'s own, in the row with its other controls.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Metrics.defaultWindow)
        .commands { VeerCommands(store: store, agent: agent) }

        MenuBarExtra {
            MenuBarContent().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }

        // The Agent in a window of its own (`AgentPresentation.detached`): the same stores, so one
        // conversation and one stream. Nothing is built for it while it is closed.
        Window(Text("Agent"), id: AgentWindow.id) {
            AgentWindow()
                .environment(store)
                .environment(agent)
                .tint(.veerAccent)
        }
        .defaultSize(AgentWindowPlacement.defaultSize)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environment(store).environment(agent).tint(.veerAccent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = makeStore(ProcessInfo.processInfo.environment)
    static let agent = makeAgent(proxy: store, ProcessInfo.processInfo.environment)
    /// Opens the main window; set by the menu bar label, which can reach `openWindow`.
    static var openMain: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read now: a static is set on first use, which would otherwise be after a change.
        _ = AppLanguage.launched
        StraySidebarItems.start()
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
        // A snapshot run's two stores are throwaway placeholders (`makeStore`); nothing to keep.
        guard !Self.isSnapshotRun(ProcessInfo.processInfo.environment) else { return }
        Self.agent.flush()
        Self.store.shutdown()
    }

    nonisolated static func isSnapshotRun(_ environment: [String: String]) -> Bool {
        environment["VEER_SNAPSHOT_DIR"] != nil
    }

    /// The store behind the app's own scenes: the main window, the menu bar and Settings open in
    /// a snapshot run too. There they get an empty store in a throwaway folder, with defaults of
    /// its own, no core and a system proxy that does nothing, so the run never reads or writes the
    /// person's profiles or preferences. The snapshots themselves draw stores of their own.
    static func makeStore(_ environment: [String: String]) -> ProxyStore {
        isSnapshotRun(environment) ? SnapshotRunner.sample(profiles: false) : ProxyStore()
    }

    /// As `makeStore`: in a snapshot run, no saved conversations, settings or keys are read.
    static func makeAgent(proxy: ProxyStore, _ environment: [String: String]) -> AgentStore {
        guard isSnapshotRun(environment) else { return AgentStore(proxy: proxy) }
        return AgentStore(proxy: proxy, keyStore: FileKeyStore(url: proxy.paths.secrets),
                          defaults: UserDefaults(suiteName: "veer-snapshot-agent-\(UUID().uuidString)")!, persist: false)
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
    @FocusedValue(\.sidebar) private var sidebar
    @AppStorage("proxiesShowMap") private var proxiesShowMap = false
    @AppStorage("proxiesShowApps") private var proxiesShowApps = false
    @AppStorage("agentWindowOnTop") private var agentWindowOnTop = false

    var body: some Commands {
        // The same native animation as the window button, including interrupted transitions.
        // Keep the standard full-screen command in the sidebar group.
        CommandGroup(before: .sidebar) { SidebarMenuButton(sidebar: sidebar) }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { Updater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("新对话") { agent.open(fresh: true) }
                .keyboardShortcut("n")
            Button("添加图片或文件…") {
                agent.open()
                agent.choosingAttachments = true
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!agent.effectiveUseAI)
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
                .disabled(!store.canSearch)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Page.sidebarPages.enumerated()), id: \.element) { index, page in
                Button(page.title) { store.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Menu(Page.tools.title) {
                ForEach(Page.allCases.filter { $0.parent == .tools }) { page in
                    Button(page.title) { store.page = page }
                }
            }
            Button("后退") { if let parent = store.page.parent { store.page = parent } }
                .keyboardShortcut("[")
                .disabled(store.page.parent == nil)
            Divider()
            // The panel: turning it on while the Agent has a window docks it back.
            Toggle("Agent 面板", isOn: Binding(get: { store.agentPanel }, set: { if $0 { agent.dock() } else { store.agentPanel = false } }))
                .keyboardShortcut("i", modifiers: [.command, .option])
            if store.agentPresentation == .detached {
                Button("停靠至主窗口") { agent.dock() }
            } else {
                Button("在独立窗口中打开 Agent") { agent.detach() }
            }
            Divider()
            // The top row's `GlassSwitch`, for anyone who cannot or does not Tab to it. Choosing one
            // goes to the page, so it never changes a view that isn't showing.
            Toggle("网格", isOn: Binding(get: { !proxiesShowMap && !proxiesShowApps }, set: { _ in
                proxiesShowMap = false
                proxiesShowApps = false
                store.page = .proxies
            }))
            .disabled(!store.isRunning || store.groups.isEmpty)
            Toggle("地图", isOn: Binding(get: { proxiesShowMap && !proxiesShowApps }, set: { _ in
                proxiesShowMap = true
                proxiesShowApps = false
                store.page = .proxies
            }))
            .disabled(!store.isRunning || store.groups.isEmpty)
            Toggle("应用分流", isOn: Binding(get: { proxiesShowApps }, set: { _ in proxiesShowApps = true; store.page = .proxies }))
                .disabled(store.profiles.isEmpty)
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            // Only this window, and only while it is open: `NSWindow.level` (`AgentWindowBridge`).
            Toggle("Agent 窗口保持在最前面", isOn: $agentWindowOnTop)
                .disabled(store.agentPresentation != .detached)
        }
        CommandMenu("代理") {
            Button(store.isRunning ? String(localized: "停止") : String(localized: "启动")) { store.isRunning ? store.stop() : store.start() }
                .keyboardShortcut("r")
                .disabled(store.activeProfile == nil || store.phase == .starting)
            Toggle("系统代理", isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!store.isRunning)
            Toggle("TUN", isOn: Binding(get: { store.settings.tun }, set: { store.setTUN($0) }))
            Toggle("允许局域网设备连接", isOn: Binding(get: { store.settings.allowLAN }, set: { store.settings.allowLAN = $0 }))
            Divider()
            Picker("使用的配置", selection: Binding(get: { store.activeProfileID }, set: { if let id = $0 { store.activate(id) } })) {
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(store.profiles.isEmpty)
            Button("更新订阅") { if let profile = store.activeProfile { store.update(profile.id) } }
                .disabled(store.activeProfile?.isSubscription != true || store.activeProfile.map { store.updatingProfiles.contains($0.id) } == true)
            Button("管理配置…") { store.manageProfiles() }
                .disabled(store.profiles.isEmpty)
            Divider()
            Picker("模式", selection: Binding(get: { store.mode }, set: { store.setMode($0) })) {
                ForEach(ProxyStore.Mode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!store.isRunning)
            Divider()
            pageCommands
        }
    }

    /// The toolbar's buttons for each page, which macOS expects in the menu bar too. Disabled, not
    /// hidden, away from their page: a menu keeps its shape.
    @ViewBuilder private var pageCommands: some View {
        let groups = store.groups, allCollapsed = !groups.isEmpty && groups.allSatisfy { store.collapsedGroups.contains($0.name) }
        Button(allCollapsed ? String(localized: "menu.expandGroups", defaultValue: "展开全部策略组")
                            : String(localized: "menu.collapseGroups", defaultValue: "收起全部策略组")) { store.setAllCollapsed(!allCollapsed) }
            .disabled(store.page != .proxies || groups.isEmpty || proxiesShowMap || proxiesShowApps)
        Divider()
        Button(store.connectionsPaused ? String(localized: "menu.resumeConnections", defaultValue: "继续刷新连接")
                                       : String(localized: "menu.pauseConnections", defaultValue: "暂停刷新连接")) { store.connectionsPaused.toggle() }
            .disabled(store.page != .connections || !store.isRunning)
        Button("关闭全部连接…") { store.confirmingCloseAllConnections = true }
            .disabled(store.page != .connections || store.connections.isEmpty)
        Divider()
        Button(String(localized: "menu.clearRequests", defaultValue: "清空请求记录")) { agent.clearRequests() }
            .disabled(store.page != .requests || store.requests.isEmpty)
        Divider()
        Button(store.logsPaused ? String(localized: "menu.resumeLogs", defaultValue: "继续记录日志")
                                : String(localized: "menu.pauseLogs", defaultValue: "暂停记录日志")) { store.logsPaused.toggle() }
            .disabled(store.page != .logs)
        Button(String(localized: "menu.clearLogs", defaultValue: "清空日志")) { agent.clearLogs() }
            .disabled(store.page != .logs || store.logs.isEmpty)
    }
}
