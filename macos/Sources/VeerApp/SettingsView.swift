import AppKit
import SwiftUI
import VeerProxy

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            ProxySettings().tabItem { Label("代理", systemImage: "network") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @Environment(ProxyStore.self) private var store
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, value in
                    value.apply()
                    languageChanged = value != AppLanguage.launched
                }
                if languageChanged {
                    HStack {
                        StatusBadge(kind: .info, text: String(localized: "重新打开 Veer 后生效。"), compact: true)
                        Spacer()
                        Button("立即重新打开") { AppLanguage.relaunch() }.neutralControl()
                    }
                }
            }
            Section {
                Toggle("打开 Veer 时恢复上次的代理状态", isOn: $store.restoreLastState)
                Toggle("在菜单栏显示实时速率", isOn: $store.showRateInMenuBar)
            } header: {
                Text("启动与菜单栏")
            } footer: {
                Text("上次退出时内核在运行，就重新启动它，并恢复模式和系统代理。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProxySettings: View {
    @Environment(ProxyStore.self) private var store
    @State private var portText = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField("代理端口", text: $portText, prompt: Text(verbatim: "7890"))
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
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(store.settings.mixedPort) }
    }

    private var portProblem: String? {
        guard let port = Int(portText) else { return portText.isEmpty ? nil : String(localized: "端口只能是数字。") }
        return (1024...65535).contains(port) ? nil : String(localized: "请使用 1024 到 65535 之间的端口。")
    }

    private func applyPort() {
        guard portProblem == nil, let port = Int(portText) else { return }
        store.settings.mixedPort = port
    }
}

/// The interface language: the system's, or one Veer sets for itself through its own
/// `AppleLanguages`, read once at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        // Each language names itself.
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    /// What this run of Veer was started with.
    static let launched = current

    /// The choice saved in Veer's own defaults, not the system-wide list.
    static var current: AppLanguage {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return own?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Quits and opens Veer again once this copy has stopped its core and released the port.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
