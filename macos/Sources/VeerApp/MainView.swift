import SwiftUI
import VeerProxy

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, proxies, profiles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .proxies: "代理"
        case .profiles: "配置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .profiles: "doc.text"
        }
    }
}

struct MainView: View {
    @Environment(ProxyStore.self) private var store
    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(Page.allCases, selection: Binding<Page?>(get: { store.page }, set: { if let page = $0 { store.page = page } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch store.page {
                case .overview: OverviewView()
                case .proxies: ProxiesView()
                case .profiles: ProfilesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.surface)
            .toolbar { toolbar }
        }
        .navigationTitle(store.page.title)
        .navigationSubtitle(store.activeProfile?.name ?? "")
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

    /// Hidden until there is a profile: without one they do nothing.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !store.profiles.isEmpty { modeAndStart }
    }

    @ToolbarContentBuilder private var modeAndStart: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SegmentedControl(label: "模式", selection: Binding(get: { store.mode }, set: { store.setMode($0) }),
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
                .help(store.activeProfile == nil ? "先导入一个配置" : "启动内核（⌘R）")
                .disabled(store.activeProfile == nil)
        }
    }
}
