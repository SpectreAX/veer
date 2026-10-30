import AppKit
import SwiftUI
import VeerProxy

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, proxies, profiles, connections, requests, logs, dns, agent

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
        case .profiles: String(localized: "配置")
        case .connections: String(localized: "连接")
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
        case .profiles: "doc.text"
        case .connections: "arrow.left.arrow.right"
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
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all

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
        .background(EmptyWindowToolbar())
        // Over the pages, which scroll under the row: a click here is the window's, not theirs.
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: 52)
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topLeading) {
            sidebarButton
                .padding(.top, 6)
                .padding(.leading, Self.windowButtonsWidth)
                .ignoresSafeArea(.container, edges: .top)
        }
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

    /// Room for the close, minimize and zoom buttons, which the sidebar button sits beside.
    private static let windowButtonsWidth: CGFloat = 88

    private var sidebarHidden: Bool { sidebarVisibility == .detailOnly }

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

    /// The page and profile, over the toolbar at the top of the page, clear of the sidebar button
    /// when there is no sidebar.
    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.page.title).font(.headline)
            if !profileName.isEmpty {
                Text(profileName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(height: 52)
        .padding(.leading, sidebarHidden ? Self.windowButtonsWidth + 52 : Spacing.lg)
        .animation(reduceMotion ? nil : Motion.standard, value: sidebarHidden)
        .allowsHitTesting(false)
    }

    /// Short enough to stay clear of the capsule in the narrowest window; the foot of the sidebar
    /// has it in full.
    private var profileName: String {
        let name = store.activeProfile?.name ?? ""
        return name.count > 18 ? name.prefix(17) + "…" : name
    }

    private var sidebarAndPage: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: Binding<Page?>(get: { store.page }, set: { if let page = $0 { store.page = page } })) {
                ForEach(Page.Section.allCases, id: \.self) { section in
                    Section(section.title) {
                        ForEach(Page.allCases.filter { $0.section == section }) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { profileFooter }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch store.page {
                case .overview: OverviewView()
                case .proxies: ProxiesView()
                case .profiles: ProfilesView()
                case .connections: ConnectionsView()
                case .requests: RequestsView()
                case .logs: LogsView()
                case .dns: DNSView()
                case .agent: AgentView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The toolbar has no band, so nothing may scroll under the title and window buttons.
            .clipped()
            .background(Color.surface)
            .overlay(alignment: .topLeading) {
                pageTitle.ignoresSafeArea(.container, edges: .top)
            }
        }
        .agentPresentations(agent)
        // For the window's name elsewhere, such as the Window menu; `pageTitle` shows it here.
        .navigationTitle(store.page.title)
    }

    /// The profile in use, at the foot of the sidebar (a click opens the profiles page), and the
    /// way into Settings.
    private var profileFooter: some View {
        HStack(spacing: Spacing.sm) {
            if let profile = store.activeProfile {
                Button { store.page = .profiles } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: profile.isSubscription ? "antenna.radiowaves.left.and.right" : "doc")
                            .foregroundStyle(.secondary)
                        Text(profile.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
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

/// Keeps the toolbar's height, which centres the window's buttons on the row and starts the pages
/// below it, with no items for it to rearrange.
private struct EmptyWindowToolbar: NSViewRepresentable {
    final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            window.toolbar = NSToolbar(identifier: "Veer")
            window.toolbarStyle = .unified
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}
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
