import SwiftUI
import VeerProxy

struct SettingsView: View {
    @Environment(ProxyStore.self) private var store
    @State private var portText = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("打开 Veer 时启动内核", isOn: $store.startCoreAtLaunch)
                Toggle("内核运行时自动开启系统代理", isOn: $store.systemProxyWhenRunning)
            } header: { Text("启动") }
            Section {
                TextField("代理端口", text: $portText, prompt: Text("7890"))
                    .onChange(of: portText) { _, _ in applyPort() }
                if let problem = portProblem {
                    StatusBadge(kind: .warning, text: problem, compact: true)
                }
                Toggle("允许局域网设备连接", isOn: $store.settings.allowLAN)
            } header: {
                Text("内核")
            } footer: {
                Text("HTTP 和 SOCKS 共用这个端口。修改后，重新启动内核才会生效。允许局域网连接后，同一网络里的设备可以把这台 Mac 当作代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { portText = String(store.settings.mixedPort) }
    }

    private var portProblem: String? {
        guard let port = Int(portText) else { return portText.isEmpty ? nil : "端口只能是数字。" }
        return (1024...65535).contains(port) ? nil : "请使用 1024 到 65535 之间的端口。"
    }

    private func applyPort() {
        guard portProblem == nil, let port = Int(portText) else { return }
        store.settings.mixedPort = port
    }
}
