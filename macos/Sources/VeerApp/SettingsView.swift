import AppKit
import SwiftUI
import VeerProxy

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(String(localized: "通用"), systemImage: "gearshape") }
            ProxySettings().tabItem { Label(String(localized: "代理"), systemImage: "network") }
            DNSSettings().tabItem { Label(String(localized: "DNS"), systemImage: "globe") }
            TUNSettings().tabItem { Label(String(localized: "TUN"), systemImage: "shield.lefthalf.filled") }
            AISettingsPane().tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsPane().tabItem { Label(String(localized: "隐私"), systemImage: "hand.raised") }
            HotKeySettings().tabItem { Label(String(localized: "快捷键"), systemImage: "keyboard") }
            AboutSettings().tabItem { Label(String(localized: "关于"), systemImage: "info.circle") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettings: View {
    @Environment(ProxyStore.self) private var store
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginProblem: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker(String(localized: "语言"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .neutralControl()
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
                Toggle(String(localized: "登录时打开 Veer"), isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        guard on != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.set(on)
                            loginProblem = LoginItem.needsApproval ? String(localized: "已加入登录项，但在系统设置中被关闭了。在“通用 → 登录项”中打开它。") : nil
                        } catch {
                            loginProblem = error.localizedDescription
                            openAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginProblem { StatusBadge(kind: .warning, text: loginProblem, compact: true) }
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
                Toggle(String(localized: "切换配置、节点或分流后断开旧连接"), isOn: $store.reconnectAfterChanges)
                Picker(String(localized: "日志级别"), selection: $store.settings.logLevel) {
                    ForEach(["error", "warning", "info", "debug"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .neutralControl()
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

/// TUN and the privileged helper it needs: its state, and installing or removing it.
struct TUNSettings: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "启用 TUN"), isOn: Binding(get: { store.settings.tun }, set: { store.setTUN($0) }))
                if let notice = store.notice {
                    StatusBadge(kind: .warning, text: notice, compact: true).fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(String(localized: "TUN 让所有应用的流量都经过 Veer，包括不读取系统代理的终端和游戏。局域网和 Tailscale 地址不走 TUN。后台服务不可用时，Veer 会改用系统代理并说明原因。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(String(localized: "状态")) {
                    if let state = store.helperState {
                        StatusBadge(kind: Self.kind(state), text: Self.title(state), compact: true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    actions
                    Spacer()
                    if store.helperBusy { ProgressView().controlSize(.small) }
                }
                .disabled(store.helperBusy)
            } header: {
                Text(String(localized: "后台服务"))
            } footer: {
                Text(String(localized: "TUN 需要以管理员身份运行内核，由一个后台服务完成。它只接受 Veer 的连接，只运行同一签名的内核，Veer 退出 10 秒后停止内核。系统设置里无法批准时（例如开发版签名），可以手动安装：输入一次管理员密码，装到 /Library。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshHelperState() }
        // Coming back from System Settings after approving it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshHelperState() }
        }
    }

    @ViewBuilder private var actions: some View {
        switch store.helperState {
        case .notInstalled?:
            Button(String(localized: "安装")) { store.registerHelper() }.primaryAction(.regular)
            Button(String(localized: "手动安装…")) { store.installHelperManually() }.neutralControl()
        case .needsApproval?:
            Button(String(localized: "打开系统设置")) { HelperClient.shared.openApprovalSettings() }.primaryAction(.regular)
            Button(String(localized: "手动安装…")) { store.installHelperManually() }.neutralControl()
            Button(String(localized: "卸载")) { store.uninstallHelper() }.neutralControl()
        case .outdated?, .unavailable?:
            Button(String(localized: "重新安装…")) { store.reinstallHelper() }.primaryAction(.regular)
            Button(String(localized: "卸载")) { store.uninstallHelper() }.neutralControl()
        case .ready?:
            Button(String(localized: "卸载")) { store.uninstallHelper() }.neutralControl()
        case nil:
            EmptyView()
        }
    }

    static func title(_ state: HelperState) -> String {
        switch state {
        case .notInstalled: String(localized: "未安装")
        case .needsApproval: String(localized: "等待在系统设置中批准")
        case .ready: HelperClient.shared.isInstalledManually ? String(localized: "已就绪（手动安装）") : String(localized: "已就绪")
        case .outdated: String(localized: "版本较旧")
        case .unavailable(let reason): reason
        }
    }

    static func kind(_ state: HelperState) -> StatusKind {
        switch state {
        case .ready: .success
        case .notInstalled: .neutral
        case .needsApproval, .outdated: .warning
        case .unavailable: .failure
        }
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
                .neutralControl()
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
