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

    private var split: some View {
        NavigationSplitView {
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
        } detail: {
            HStack(spacing: 0) {
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
                .background(Color.surface)
                // On every page but the Agent page, which is the Agent at full size. A plain
                // column, not `.inspector`: changing an inspector again before its collapse has
                // finished makes AppKit raise over a view it has already removed, ending the app.
                if store.agentPanel && store.page != .agent {
                    AgentPanelColumn()
                }
            }
            .toolbar { toolbar }
        }
        .agentPresentations(agent)
        .navigationTitle(store.page.title)
        .navigationSubtitle(store.activeProfile?.name ?? "")
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

    /// Hidden until there is a profile: without one they do nothing.
    /// Start and stop and the Agent panel; the mode lives on the overview's card, the menu bar and the 代理 menu.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !store.profiles.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                StartStopButton()
            }
            if store.page != .agent {
                ToolbarItem(placement: .primaryAction) {
                    @Bindable var store = store
                    Toggle(isOn: $store.agentPanel) { Label(String(localized: "Agent 面板"), systemImage: "sparkles") }
                        .help(store.agentPanel ? String(localized: "隐藏 Agent 面板（⌥⌘I）") : String(localized: "显示 Agent 面板（⌥⌘I）"))
                }
            }
        }
    }
}

/// A page that later steps fill in.
struct ComingLaterView: View {
    let page: Page
    let message: String

    var body: some View {
        StateView(symbol: page.symbol, title: String(localized: "“\(page.title)”页即将推出"), message: message)
    }
}

/// The one primary action: start or stop the core.
struct StartStopButton: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        switch store.phase {
        case .starting:
            Button {} label: { Label("正在启动", systemImage: "hourglass") }.disabled(true)
        case .running:
            Button { store.stop() } label: { Label("停止", systemImage: "stop.fill") }
                .help("停止内核（⌘R）")
        case .stopped, .failed:
            Button { store.start() } label: { Label("启动", systemImage: "play.fill") }
                .help(store.activeProfile == nil ? String(localized: "先导入一个配置") : String(localized: "启动内核（⌘R）"))
                .disabled(store.activeProfile == nil)
        }
    }
}
