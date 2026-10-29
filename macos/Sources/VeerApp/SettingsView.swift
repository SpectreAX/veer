import AppKit
import SwiftUI
import VeerProxy

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(String(localized: "通用"), systemImage: "gearshape") }
            ProxySettings().tabItem { Label(String(localized: "代理"), systemImage: "network") }
            DNSSettings().tabItem { Label(String(localized: "DNS"), systemImage: "globe") }
            AISettingsPane().tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsPane().tabItem { Label(String(localized: "隐私"), systemImage: "hand.raised") }
        }
        .frame(width: 560)
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
                Picker(String(localized: "语言"), selection: $language) {
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
                        Button(String(localized: "立即重新打开")) { AppLanguage.relaunch() }.neutralControl()
                    }
                }
            }
            Section {
                Toggle(String(localized: "打开 Veer 时恢复上次的代理状态"), isOn: $store.restoreLastState)
                Toggle(String(localized: "在菜单栏显示实时速率"), isOn: $store.showRateInMenuBar)
                Toggle(String(localized: "在概览中检测出口 IP"), isOn: $store.showExitIP)
            } header: {
                Text(String(localized: "启动与菜单栏"))
            } footer: {
                Text(String(localized: "上次退出时内核在运行，就重新启动它，并恢复模式和系统代理。"))
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
                TextField(String(localized: "代理端口"), text: $portText, prompt: Text(verbatim: "7890"))
                    .onChange(of: portText) { _, _ in applyPort() }
                if let problem = portProblem {
                    StatusBadge(kind: .warning, text: problem, compact: true)
                }
                Toggle(String(localized: "允许局域网设备连接"), isOn: $store.settings.allowLAN)
                Toggle(String(localized: "IPv6"), isOn: $store.settings.ipv6)
                Toggle(String(localized: "按进程匹配"), isOn: $store.settings.processMatching)
                Toggle(String(localized: "禁用 QUIC"), isOn: $store.settings.disableQUIC)
                Picker(String(localized: "日志级别"), selection: $store.settings.logLevel) {
                    ForEach(["error", "warning", "info", "debug"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
            } header: {
                Text(String(localized: "内核"))
            } footer: {
                Text(String(localized: "HTTP 和 SOCKS 共用这个端口，修改端口后重新启动内核才会生效；其他设置立即生效。按进程匹配让规则能按应用分流，连接页也会显示进程名。禁用 QUIC 会拒绝 UDP 443 端口的连接，浏览器会改用更适合代理的 TCP。"))
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
        case .simplifiedChinese: String(localized: "简体中文")
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

/// How the core resolves names when the profile does not say.
struct DNSSettings: View {
    @Environment(ProxyStore.self) private var store
    @State private var servers = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle(String(localized: "配置自带 DNS 时优先使用"), isOn: $store.settings.preferProfileDNS)
                Picker(String(localized: "模式"), selection: $store.settings.dnsMode) {
                    Text(verbatim: "fake-ip").tag(RuntimeSettings.DNSMode.fakeIP)
                    Text(verbatim: "redir-host").tag(RuntimeSettings.DNSMode.redirHost)
                }
            } footer: {
                Text(String(localized: "大多数订阅自带 DNS 设置，默认沿用它们。fake-ip 解析更快，开启 TUN 时需要；redir-host 返回真实地址。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                TextEditor(text: $servers)
                    .font(Typography.code)
                    .frame(minHeight: 72)
                    .onChange(of: servers) { _, text in
                        let list = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if !list.isEmpty, list != store.settings.dnsServers { store.settings.dnsServers = list }
                    }
                Button(String(localized: "恢复默认")) { servers = RuntimeSettings.defaultDNSServers.joined(separator: "\n") }
                    .neutralControl()
            } header: {
                Text(String(localized: "上游服务器"))
            } footer: {
                Text(String(localized: "每行一个，支持 DoH（https://）、DoT（tls://）和普通地址。也用来解析代理服务器自己的域名。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { servers = store.settings.dnsServers.joined(separator: "\n") }
    }
}
