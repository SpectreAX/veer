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
    @State private var panelReveal = ColumnReveal()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var activeState
    @State private var isFullScreen = false
    @State private var roomyTitle = true
    @Namespace private var splitCoordinateSpace
    @State private var sidebarAnimator: SidebarAnimator

    init(sidebarVisibility: NavigationSplitViewVisibility = .all, sidebarAnimator: SidebarAnimator? = nil) {
        _sidebarAnimator = State(initialValue: sidebarAnimator ?? SidebarAnimator(isHidden: sidebarVisibility == .detailOnly))
    }

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
        // Onboarding has no sidebar, so the menu command is unavailable there.
        .focusedSceneValue(\.sidebar, store.onboarding == nil ? sidebarAnimator : nil)
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
            if panelReveal.progress > 0 {
                AgentPanelColumn()
                    .padding(.top, fullScreenTopInset)
                    .background(Color.surface)
                    .overlay(alignment: .top) { dragRow }
                    // Narrowed from its leading edge, so it slides in from the window's edge.
                    .frame(width: panelReveal.progress < 1 ? AgentPanelColumn.width(store) * panelReveal.progress : nil, alignment: .leading)
                    .clipped()
            }
        }
        // Opening and closing slide; going to and from the Agent page swaps pages at once.
        .onChange(of: store.agentPanel) { _, open in panelReveal.animate(to: open && store.page != .agent, reduceMotion: reduceMotion) }
        .onChange(of: store.page, initial: true) { _, page in panelReveal.jump(to: store.agentPanel && page != .agent) }
        // What the page shows for the panel, such as the overview's ask bar.
        .animation(reduceMotion ? nil : Motion.standard, value: store.agentPanel)
        // The band would stop at the panel, which is outside the split view; the capsule floats.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // The window's controls float over the toolbar, which is left with nothing in it. As the
        // sidebar opens the toolbar runs short of room for a few frames, whatever the window's
        // width, and any item it holds lands in an overflow button that throws the rest aside. An
        // item's content also snaps to a new page rather than animating.
        .background(EmptyWindowToolbar(isFullScreen: $isFullScreen))
        .onGeometryChange(for: Bool.self) { $0.size.width >= Metrics.roomyTitleWidth } action: { roomyTitle = $0 }
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

    private var sidebarHidden: Bool { sidebarAnimator.isHidden }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarAnimator.nativeHidden ? .detailOnly : .all },
                set: { sidebarAnimator.nativeVisibilityChanged(hidden: $0 == .detailOnly) })
    }

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
    /// opens and closes. Its padding keeps it clear of the sidebar button and comes from where the
    /// column is, frame by frame: animated on a curve of its own, it fell behind the column and the
    /// title crossed the window's buttons.
    private var titleRow: some View {
        ClearOfSidebarButton(clearance: sidebarButtonLeading + 52) {
            HStack(spacing: Spacing.sm) {
                if let parent = store.page.parent { backButton(to: parent) }
                pageTitle
            }
            .frame(height: Self.topRowHeight)
        }
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
            toggleSidebar()
        } label: {
            Label(sidebarHidden ? String(localized: "显示边栏") : String(localized: "隐藏边栏"), systemImage: "sidebar.left")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle())
        .labelStyle(.iconOnly)
        .help(sidebarHidden ? String(localized: "显示边栏") : String(localized: "隐藏边栏"))
        .padding(Spacing.xs)
        .glassSurface(in: Circle())
    }

    private func toggleSidebar() {
        sidebarAnimator.toggle(reduceMotion: reduceMotion)
    }

    /// The page, which a click on goes through to the window, and the profile's menu.
    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.page.title).font(.headline).allowsHitTesting(false)
            if !profileName.isEmpty { ProfileMenu(name: profileName) }
        }
        .lineLimit(1)
    }

    /// Short enough to stay clear of the toolbar, even with the sidebar at its widest in the smallest
    /// window. The menu it opens has it in full.
    private var profileName: String {
        (store.activeProfile?.name ?? "").shortened(toFit: roomyTitle ? 160 : 90, font: .preferredFont(forTextStyle: .caption1))
    }

    private var sidebarAndPage: some View {
        GeometryReader { split in
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                SidebarRevealLayout(width: sidebarAnimator.isAnimating ? sidebarAnimator.width : nil) {
                List(selection: Binding<Page?>(get: { store.page.parent ?? store.page }, set: { if let page = $0 { store.page = page } })) {
                    ForEach(Page.Section.allCases, id: \.self) { section in
                        Section(section.title) {
                            ForEach(Page.sidebarPages.filter { $0.section == section }) { page in
                                Label {
                                    Text(page.title)
                                } icon: {
                                    // By hand: the list's own tint stays on it when the row isn't what it thinks is selected.
                                    // White only on the accent fill, which a window in the background doesn't show.
                                    Image(systemName: page.symbol)
                                        .foregroundStyle((store.page.parent ?? store.page) == page && activeState != .inactive
                                            ? Color.onAccent : Color.accentColor)
                                }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .selectionHighlight((store.page.parent ?? store.page) == page)
                                    // The list reports no change for the row already selected, which
                                    // a subpage's parent is, and a click there should go back to it.
                                    .simultaneousGesture(TapGesture().onEnded {
                                        if store.page.parent == page { store.page = page }
                                    })
                                    .tag(page)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { appFooter }
                .safeAreaPadding(.top, fullScreenTopInset)
                .overlay(alignment: .top) { dragRow }
                .toolbar(removing: .sidebarToggle)
                }
                .background(SidebarAnimationHost(sidebarAnimator))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarAnimator.rememberWidth($0) }
                .navigationSplitViewColumnWidth(min: sidebarAnimator.minimumWidth,
                                                ideal: sidebarAnimator.isAnimating ? sidebarAnimator.maximumWidth : sidebarAnimator.width,
                                                max: sidebarAnimator.maximumWidth)
            } detail: {
                SplitDetailViewport(splitWidth: split.size.width, coordinateSpace: splitCoordinateSpace) {
                    pageContent
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // The toolbar has no band, so nothing may scroll under the title and window buttons.
                .clipped()
                .padding(.top, fullScreenTopInset)
                .background(Color.surface)
                .overlay(alignment: .top) { dragRow }
                .overlay(alignment: .topLeading) { titleRow }
                .navigationSplitViewColumnWidth(min: 0, ideal: Metrics.readingWidth, max: .infinity)
            }
            .agentPresentations(agent)
            // For the window's name elsewhere, such as the Window menu; `pageTitle` shows it here.
            .navigationTitle(store.page.title)
        }
        .coordinateSpace(name: splitCoordinateSpace)
    }

    private var pageContent: some View {
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
    }

    /// What this is and which version, at the foot of the sidebar, and the way into Settings. The
    /// profile is under the page's title.
    private var appFooter: some View {
        HStack(spacing: Spacing.sm) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Spacing.xxl, height: Spacing.xxl)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Veer").font(.headline)
                Text(verbatim: AboutSettings.version).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
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

/// Content at the leading edge of the page's column, in line with the page's cards, or further in
/// while the column sits under the sidebar button. It measures where it is itself, so only this
/// view is drawn again as the split view moves the column, and not the page beside it.
private struct ClearOfSidebarButton<Content: View>: View {
    let clearance: CGFloat
    @ViewBuilder let content: Content
    @State private var leading: CGFloat = Metrics.sidebarWidth

    var body: some View {
        content
            .padding(.leading, max(Spacing.xl, clearance - leading))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { leading = $0 }
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
            Button("管理配置") { store.manageProfiles() }
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
