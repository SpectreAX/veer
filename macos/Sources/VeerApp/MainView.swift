import AppKit
import SwiftUI
import VeerProxy

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, proxies, connections, tools, requests, logs, dns, agent

    /// What the sidebar lists, in order, for ⌘1 onward. The rest are subpages of Tools.
    static let sidebarPages: [Page] = [.overview, .proxies, .connections, .tools, .agent]

    /// The page a subpage goes back to.
    var parent: Page? {
        switch self {
        case .requests, .logs, .dns: .tools
        default: nil
        }
    }

    enum Section: CaseIterable {
        case proxy, ai
        var title: String {
            switch self {
            case .proxy: String(localized: "代理")
            case .ai: String(localized: "AI")
            }
        }
    }

    var id: String { rawValue }
    var section: Section { self == .agent ? .ai : .proxy }
    var title: String {
        switch self {
        case .overview: String(localized: "概览")
        // "代理" also names the sidebar section; the page needs its own key.
        case .proxies: String(localized: "page.proxies", defaultValue: "代理")
        case .connections: String(localized: "连接")
        case .tools: String(localized: "工具")
        case .requests: String(localized: "请求")
        case .logs: String(localized: "日志")
        case .dns: String(localized: "DNS")
        case .agent: String(localized: "Agent")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .connections: "arrow.left.arrow.right"
        case .tools: "wrench.and.screwdriver"
        case .requests: "clock.arrow.circlepath"
        case .logs: "text.alignleft"
        case .dns: "globe"
        case .agent: "sparkles"
        }
    }
}

struct MainView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    @State private var isFullScreen = false

    /// The window's top row, which the sidebar button, the title and the capsule float in.
    static let topRowHeight: CGFloat = 52

    var body: some View {
        @Bindable var store = store
        Group {
            if store.onboarding != nil {
                OnboardingView()
            } else {
                split
            }
        }
        .sheet(isPresented: $store.showingImport) { ImportSheet() }
        // A config file from Finder imports at once; a link opens the import sheet to confirm.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.isFileURL { store.importFile(url) } else { store.openImport(prefill: url.absoluteString) }
            return true
        }
        .onAppear { DockPresence.windowOpened() }
        .onChange(of: undoManager, initial: true) { _, manager in agent.changes.manager = manager }
        .onDisappear { DockPresence.windowClosed() }
    }

    /// The sidebar and page, with the Agent panel outside them: collapsing a sidebar gives the
    /// detail column its final width at once and then slides it, which would throw anything inside
    /// it past the window's edge.
    private var split: some View {
        HStack(spacing: 0) {
            sidebarAndPage
                .frame(minWidth: 0, maxWidth: .infinity)
            // On every page but the Agent page, which is the Agent at full size. A plain column,
            // not `.inspector`: changing an inspector again before its collapse has finished makes
            // AppKit raise over a view it has already removed, ending the app.
            if store.agentPanel && store.page != .agent {
                AgentPanelColumn()
                    .padding(.top, fullScreenTopInset)
                    .background(Color.surface)
                    .overlay(alignment: .top) { dragRow }
                    .transition(.move(edge: .trailing))
            }
        }
        // Only for opening and closing: going to and from the Agent page swaps pages at once.
        .animation(reduceMotion ? nil : Motion.standard, value: store.agentPanel)
        // The band would stop at the panel, which is outside the split view; the capsule floats.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // The window's controls float over the toolbar, which is left with nothing in it. As the
        // sidebar opens the toolbar runs short of room for a few frames, whatever the window's
        // width, and any item it holds lands in an overflow button that throws the rest aside. An
        // item's content also snaps to a new page rather than animating.
        .background(EmptyWindowToolbar(isFullScreen: $isFullScreen))
        .overlay(alignment: .topLeading) {
            sidebarButton
                .padding(.top, 6)
                .padding(.leading, sidebarButtonLeading)
                .ignoresSafeArea(.container, edges: .top)
        }
        // The Agent shows these itself. Elsewhere Edit → Undo would otherwise change routing with no sign.
        .overlay(alignment: .bottom) {
            if store.page != .agent, !store.agentPanel, let toast = agent.toast {
                ToastView(toast: toast) { agent.undo() }
                    .padding(.bottom, Spacing.xl)
                    .transition(reduceMotion ? AnyTransition.opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.standard, value: agent.toast)
        .overlayPreferenceValue(PageToolbarKey.self) { content in
            // Hidden until there is a profile: without one they do nothing.
            if !store.profiles.isEmpty {
                ToolbarCapsule(content: content)
                    .padding([.top, .trailing], 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    /// Full screen has no toolbar to start the columns below the row (see `EmptyWindowToolbar`). For
    /// each column: a split view passes no safe area from outside it on to them.
    private var fullScreenTopInset: CGFloat { isFullScreen ? Self.topRowHeight : 0 }

    /// Room for the close, minimize and zoom buttons, which the sidebar button sits beside. Full
    /// screen hides them, and the button takes their place.
    private var sidebarButtonLeading: CGFloat { isFullScreen ? Spacing.sm : 88 }

    private var sidebarHidden: Bool { sidebarVisibility == .detailOnly }

    /// Over a column, which scrolls under the row: a click here is the window's, not the column's.
    /// In each column rather than over them all, so that the page's title can sit above it and take
    /// clicks on its menu. A full-screen window does not move.
    @ViewBuilder private var dragRow: some View {
        if !isFullScreen {
            WindowDragArea()
                .frame(height: Self.topRowHeight)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// The back button, page and profile, in the page's column and so moving with it as the sidebar
    /// opens and closes: its position can't be measured from outside, as a split view reports wild
    /// values for the column while it animates. Clear of the sidebar button when there is no sidebar.
    private var titleRow: some View {
        HStack(spacing: Spacing.sm) {
            if let parent = store.page.parent { backButton(to: parent) }
            pageTitle
        }
        .frame(height: Self.topRowHeight)
        // In line with the page's cards, which start this far in.
        .padding(.leading, sidebarHidden ? sidebarButtonLeading + 52 : Spacing.xl)
        .animation(reduceMotion ? nil : Motion.standard, value: sidebarHidden)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func backButton(to parent: Page) -> some View {
        Button { store.page = parent } label: {
            Label(String(localized: "返回“\(parent.title)”"), systemImage: "chevron.left")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle())
        .labelStyle(.iconOnly)
        .help(String(localized: "返回“\(parent.title)”（⌘[）"))
        .padding(Spacing.xs)
        .glassSurface(in: Circle())
    }

    private var sidebarButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .default) { sidebarVisibility = sidebarHidden ? .all : .detailOnly }
        } label: {
            Label(sidebarHidden ? String(localized: "显示边栏") : String(localized: "隐藏边栏"), systemImage: "sidebar.left")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle())
        .labelStyle(.iconOnly)
        .help(sidebarHidden ? String(localized: "显示边栏") : String(localized: "隐藏边栏"))
        .padding(Spacing.xs)
        .glassSurface(in: Circle())
    }

    /// The page, which a click on goes through to the window, and the profile's menu.
    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.page.title).font(.headline).allowsHitTesting(false)
            if !profileName.isEmpty { ProfileMenu(name: profileName) }
        }
        .lineLimit(1)
    }

    /// Short enough to stay clear of the capsule in the narrowest window; the foot of the sidebar
    /// has it in full.
    private var profileName: String {
        let name = store.activeProfile?.name ?? ""
        return name.count > 18 ? name.prefix(17) + "…" : name
    }

    private var sidebarAndPage: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: Binding<Page?>(get: { store.page.parent ?? store.page }, set: { if let page = $0 { store.page = page } })) {
                ForEach(Page.Section.allCases, id: \.self) { section in
                    Section(section.title) {
                        ForEach(Page.sidebarPages.filter { $0.section == section }) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { profileFooter }
            .safeAreaPadding(.top, fullScreenTopInset)
            .overlay(alignment: .top) { dragRow }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch store.page {
                case .overview: OverviewView()
                case .proxies: ProxiesView()
                case .connections: ConnectionsView()
                case .tools: ToolsView()
                case .requests: RequestsView()
                case .logs: LogsView()
                case .dns: DNSView()
                case .agent: AgentView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The toolbar has no band, so nothing may scroll under the title and window buttons.
            .clipped()
            .padding(.top, fullScreenTopInset)
            .background(Color.surface)
            .overlay(alignment: .top) { dragRow }
            .overlay(alignment: .topLeading) { titleRow }
        }
        .agentPresentations(agent)
        // For the window's name elsewhere, such as the Window menu; `pageTitle` shows it here.
        .navigationTitle(store.page.title)
    }

    /// The profile in use, at the foot of the sidebar (a click opens the proxies page, which lists them), and the
    /// way into Settings.
    private var profileFooter: some View {
        HStack(spacing: Spacing.sm) {
            if let profile = store.activeProfile {
                Button { store.page = .proxies } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: profile.isSubscription ? "antenna.radiowaves.left.and.right" : "doc")
                            .foregroundStyle(.secondary)
                        // Not beside a Spacer, which would take half of what the name could use.
                        Text(profile.name).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "当前配置：\(profile.name)"))
            } else {
                Spacer(minLength: 0)
            }
            // A plain button rather than SettingsLink, which leaves VoiceOver with only "button".
            Button { openSettings() } label: {
                Label(String(localized: "设置"), systemImage: "gearshape").labelStyle(.iconOnly).imageScale(.large)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "设置（⌘,）"))
        }
        .font(.callout)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }
}

/// The profile in use, under the page's title on every page, where the HIG keeps a document's menu:
/// how much of it is left, every profile to switch to, and the way to manage them.
private struct ProfileMenu: View {
    @Environment(ProxyStore.self) private var store
    let name: String

    var body: some View {
        Menu {
            if let usage {
                Text(usage)
                Divider()
            }
            Picker(String(localized: "使用的配置"), selection: Binding(get: { store.activeProfileID }, set: { if let id = $0 { store.activate(id) } })) {
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            if let profile = store.activeProfile, profile.isSubscription {
                Button("更新订阅") { store.update(profile.id) }
                    .disabled(store.updatingProfiles.contains(profile.id))
            }
            Button("管理配置") { store.page = .proxies }
            Button("导入配置…") { store.openImport() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(verbatim: name)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        // Not the borderless style, which insets its label and so can't line up with the title above.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "当前配置：\(store.activeProfile?.name ?? "—")"))
        .accessibilityLabel(String(localized: "使用的配置"))
        .accessibilityValue(store.activeProfile?.name ?? "")
    }

    private var usage: String? {
        guard let usage = store.activeProfile?.usage, let total = usage.total, total > 0 else { return nil }
        let used = String(localized: "已用 \(Format.bytes(usage.used ?? 0)) / \(Format.bytes(total))")
        guard let expire = usage.expire else { return used }
        let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: expire).day ?? 0)
        return [used, String(localized: "剩 \(days) 天")].joined(separator: " · ")
    }
}

/// Keeps the toolbar's height, which centres the window's buttons on the row and starts the pages
/// below it, with no items for it to rearrange.
///
/// In full screen AppKit moves a toolbar to a window of its own, in front of this one, and it would
/// cover everything floating in the row. So the toolbar comes off for full screen and the row is
/// `MainView`'s to keep: hiding it is not enough, as entering full screen shows it again. AppKit,
/// because `windowToolbarFullScreenVisibility` needs macOS 15 and this runs on 14.
private struct EmptyWindowToolbar: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    final class Host: NSView {
        var onFullScreen: ((Bool) -> Void)?
        private let toolbar = NSToolbar(identifier: "Veer")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            center.addObserver(self, selector: #selector(enteringFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(leavingFullScreen), name: NSWindow.willExitFullScreenNotification, object: window)
            // A window restored to full screen is there before this view is.
            setToolbar(fullScreen: window.styleMask.contains(.fullScreen))
            // Later, and read then: this can run while SwiftUI is updating the view that owns the
            // state, and the window can already be on its way into full screen.
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                onFullScreen?(window.styleMask.contains(.fullScreen))
            }
        }

        @objc private func enteringFullScreen() {
            setToolbar(fullScreen: true)
            onFullScreen?(true)
        }

        @objc private func leavingFullScreen() {
            setToolbar(fullScreen: false)
            onFullScreen?(false)
        }

        private func setToolbar(fullScreen: Bool) {
            window?.toolbar = fullScreen ? nil : toolbar
            window?.toolbarStyle = .unified
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.onFullScreen = { isFullScreen = $0 }
        return host
    }

    func updateNSView(_ view: Host, context: Context) {
        view.onFullScreen = { isFullScreen = $0 }
    }
}

/// The top row of the window, which moves it as a title bar does. With no items in the toolbar,
/// clicks pass through it to whatever is below.
private struct WindowDragArea: NSViewRepresentable {
    final class Area: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) {}
}

/// A page that later steps fill in.
struct ComingLaterView: View {
    let page: Page
    let message: String

    var body: some View {
        StateView(symbol: page.symbol, title: String(localized: "“\(page.title)”页即将推出"), message: message)
    }
}

/// The one primary action: start or stop the core. One button whatever the phase, so its hover and
/// press survive a change and only the symbol moves.
struct StartStopButton: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if store.phase == .running { store.stop() } else { store.start() }
        } label: {
            Label(title, systemImage: symbol)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .help(help)
        .disabled(store.phase == .starting || (store.phase != .running && store.activeProfile == nil))
        .animation(reduceMotion ? nil : Motion.quick, value: symbol)
    }

    private var symbol: String {
        switch store.phase {
        case .starting: "hourglass"
        case .running: "stop.fill"
        case .stopped, .failed: "play.fill"
        }
    }

    private var title: String {
        switch store.phase {
        case .starting: String(localized: "正在启动")
        case .running: String(localized: "停止")
        case .stopped, .failed: String(localized: "启动")
        }
    }

    private var help: String {
        switch store.phase {
        case .starting: ""
        case .running: String(localized: "停止内核（⌘R）")
        case .stopped, .failed: store.activeProfile == nil ? String(localized: "先导入一个配置") : String(localized: "启动内核（⌘R）")
        }
    }
}
