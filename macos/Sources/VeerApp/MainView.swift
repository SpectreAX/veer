import SwiftUI
import VeerProxy

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, proxies, profiles, connections, logs, agent

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
        case .logs: String(localized: "日志")
        case .agent: String(localized: "Agent")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .profiles: "doc.text"
        case .connections: "arrow.left.arrow.right"
        case .logs: "text.alignleft"
        case .agent: "sparkles"
        }
    }
}

struct MainView: View {
    @Environment(ProxyStore.self) private var store
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
            Group {
                switch store.page {
                case .overview: OverviewView()
                case .proxies: ProxiesView()
                case .profiles: ProfilesView()
                case .connections: ConnectionsView()
                case .logs: LogsView()
                case .agent: AgentView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.surface)
            .toolbar { toolbar }
        }
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
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !store.profiles.isEmpty { modeAndStart }
    }

    @ToolbarContentBuilder private var modeAndStart: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SegmentedControl(label: String(localized: "模式"), selection: Binding(get: { store.mode }, set: { store.setMode($0) }),
                             options: ProxyStore.Mode.allCases.map { .init(value: $0, title: $0.title) })
                .fixedSize()
                .disabled(!store.isRunning)
            .help("规则：按配置分流；全局：全部走所选出口；直连：都不走代理")
        }
        ToolbarItem(placement: .primaryAction) {
            StartStopButton()
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
