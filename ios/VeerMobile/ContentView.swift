import SwiftUI
import VeerCore

/// The three tabs (design spec §5). Settings and Import are app-wide sheets so the Agent and
/// Proxies tabs can open them too.
struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: Tab = .overview

    enum Tab: Hashable { case overview, proxies, agent }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("概览", systemImage: "gauge.with.dots.needle.33percent", value: Tab.overview) {
                OverviewTab()
            }
            .accessibilityIdentifier("tab-overview")
            SwiftUI.Tab("page.proxies", systemImage: "point.3.connected.trianglepath.dotted", value: Tab.proxies) {
                ProxiesTab()
            }
            .accessibilityIdentifier("tab-proxies")
            SwiftUI.Tab("Agent", systemImage: "sparkles", value: Tab.agent) {
                AgentTab()
            }
            .accessibilityIdentifier("tab-agent")
        }
        .tint(.veerAccent)
        .environment(model)
        .environment(model.proxy)
        .environment(model.agent)
        .sheet(isPresented: Bindable(model).showingSettings) {
            SettingsSheet().environment(model).environment(model.proxy).environment(model.agent)
        }
        .sheet(isPresented: Bindable(model).showingImport) {
            ImportSheet().environment(model).environment(model.proxy)
        }
        .task { model.applyLaunchArguments() }
    }
}
