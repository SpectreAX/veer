import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// `VEER_SNAPSHOT_DIR=… Veer`: renders each screen and state, light and dark, from sample data
/// in a throwaway directory. It never starts a core or touches the system proxy.
enum SnapshotRunner {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances = (ProcessInfo.processInfo.environment["VEER_SNAPSHOT_APPEARANCE"] ?? "light,dark").split(separator: ",").map(String.init)
        // `VEER_SNAPSHOT_SCENES=05,25`: only the scenes whose names start with these.
        let only = ProcessInfo.processInfo.environment["VEER_SNAPSHOT_SCENES"]?.split(separator: ",").map(String.init)
        Task { @MainActor in
            for appearance in appearances {
                let name = appearance == "dark" ? NSAppearance.Name.darkAqua : .aqua
                for scene in scenes() where only?.contains(where: scene.name.hasPrefix) ?? true {
                    let store = scene.store()
                    let agent = AgentStore(proxy: store, keyStore: FileKeyStore(url: store.paths.secrets),
                                           defaults: UserDefaults(suiteName: "veer-snapshot-agent-\(UUID().uuidString)")!, persist: false)
                    scene.agent?(agent)
                    // The app's window never gets smaller than this; content sized views would shrink it.
                    let view = scene.fullScreen
                        ? AnyView(scene.view.environment(store).environment(agent).tint(.veerAccent))
                        : AnyView(scene.view.environment(store).environment(agent).tint(.veerAccent).frame(width: scene.size.width, height: scene.size.height))
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: scene.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: name)
                    // As `.windowStyle(.hiddenTitleBar)` leaves the app's window.
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.contentViewController = NSHostingController(rootView: view)
                    window.setContentSize(scene.size)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    let path = directory.appendingPathComponent("\(scene.name)-\(appearance).png")
                    if scene.fullScreen {
                        await captureFullScreen(window, to: path)
                    } else {
                        try? await Task.sleep(for: .milliseconds(700))
                        capture(window, to: path)
                    }
                    window.orderOut(nil)
                }
                // Laid out and shown, never run: nothing here can register the helper.
                for (consent, suffix) in [(HelperState.TUNConsent.install, "install"), (.approve, "approve")] {
                    let alert = HelperPrompt.alert(for: consent)
                    alert.window.appearance = NSAppearance(named: name)
                    alert.layout()
                    alert.window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    try? await Task.sleep(for: .milliseconds(900))
                    capture(alert.window, to: directory.appendingPathComponent("33-tun-\(suffix)-\(appearance).png"))
                    alert.window.orderOut(nil)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func mapDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!
        defaults.set(true, forKey: "proxiesShowMap")
        return defaults
    }

    struct Scene {
        let name: String
        var size = CGSize(width: 1080, height: 720)
        let store: () -> ProxyStore
        let view: AnyView
        /// Fills the Agent page's state, for its scenes.
        var agent: ((AgentStore) -> Void)? = nil
        /// Takes the window into full screen, in its own Space, for the capture.
        var fullScreen = false
    }

    // swiftlint:disable:next function_body_length
    static func scenes() -> [Scene] { // A flat list that grows with every screen.
        [
            Scene(name: "01-onboarding-add", store: { sample(profiles: false) }, view: AnyView(MainView())),
            Scene(name: "02-onboarding-routing", store: {
                let store = sample()
                store.onboarding = .routing
                return store
            }, view: AnyView(MainView())),
            Scene(name: "03-onboarding-start", store: {
                let store = running()
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "04-overview-running", store: { running() }, view: AnyView(MainView())),
            Scene(name: "05-proxies", store: { running(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "06-profiles", store: { running(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "06b-tools", store: { running(page: .tools) }, view: AnyView(MainView())),
            Scene(name: "04d-overview-detecting", store: {
                let store = running()
                store.exit = nil
                return store
            }, view: AnyView(MainView())),
            // Nothing reaches the core, while the exit still looks right.
            Scene(name: "04g-overview-no-proxy", store: {
                let store = running()
                store.systemProxyOn = false
                return store
            }, view: AnyView(MainView())),
            Scene(name: "04h-overview-lan", store: { running(lan: true) }, view: AnyView(MainView())),
            // Stopped with the proxy remembered, and with LAN on: neither is in effect yet.
            Scene(name: "04i-overview-stopped", store: {
                let store = running(lan: true)
                store.phase = .stopped
                store.systemProxyOn = false
                store.exit = nil
                store.systemProxyRemembered = true
                return store
            }, view: AnyView(MainView())),
            // The address's narrowest place, beside the Agent panel in the smallest window.
            Scene(name: "24e-panel-narrow-lan", size: CGSize(width: 860, height: 640), store: { running(panel: true, lan: true) }, view: AnyView(MainView())),
            Scene(name: "04f-overview-starting", store: {
                let store = running()
                store.phase = .starting
                return store
            }, view: AnyView(MainView())),
            // Long enough to wrap: this page has no scroll of its own up there.
            Scene(name: "05c-proxies-notice-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .proxies)
                store.notice = String(localized: "TUN 未能启动，已改用系统代理。\(String(localized: "需要在系统设置的“登录项”中允许 Veer 的后台服务。"))")
                return store
            }, view: AnyView(MainView())),
            Scene(name: "05b-proxies-smallest", size: CGSize(width: 860, height: 560), store: { running(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "04e-overview-no-exit", store: {
                let store = running()
                store.exit = .unknown
                return store
            }, view: AnyView(MainView())),
            // A failed start is explained wherever it was started from.
            Scene(name: "07b-failed-proxies", store: { failed(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "07c-failed-connections", store: { failed(page: .connections) }, view: AnyView(MainView())),
            Scene(name: "07d-failed-dns", store: { failed(page: .dns) }, view: AnyView(MainView())),
            Scene(name: "07e-failed-logs", store: { failed(page: .logs) }, view: AnyView(MainView())),
            Scene(name: "07f-failed-requests", store: { failed(page: .requests) }, view: AnyView(MainView())),
            // Onboarding has no scroll, so this has to fit the smallest window.
            Scene(name: "03c-onboarding-failed-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = failed(page: .overview)
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "03b-onboarding-failed", store: {
                let store = failed(page: .overview)
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "07-failed", store: {
                let store = sample()
                store.phase = .failed(String(localized: "端口 \(String(7890)) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。"), log: [
                    "time=\"2026-10-29T10:00:00+08:00\" level=info msg=\"Start initial configuration in progress\"",
                    "time=\"2026-10-29T10:00:00+08:00\" level=error msg=\"Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use\"",
                ])
                return store
            }, view: AnyView(MainView())),
            Scene(name: "08-proxies-stopped", store: {
                let store = sample()
                store.page = .proxies
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09-agent-setup", store: { running(page: .agent) }, view: AnyView(MainView())),
            Scene(name: "09b-agent-welcome", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
            }),
            Scene(name: "09c-agent-proposal", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            // Five suggestions on the Agent page once pushed the window's content past its top.
            Scene(name: "09j-agent-suggestions", store: {
                let store = running(page: .agent)
                store.suggestions = ["a.example.com", "b.example.com", "c.example.com", "d.example.com"].map { Suggestion(kind: .unmatched(host: $0, count: 5)) }
                    + [Suggestion(kind: .failing(host: "ipv6.itdog.cn", count: 3))]
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            Scene(name: "09d-agent-applied", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }),
            Scene(name: "24-panel-overview", store: { running(panel: true) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            Scene(name: "24b-panel-setup", store: { running(panel: true) }, view: AnyView(MainView())),
            // The smallest window: the overview's rows stack beside the panel.
            Scene(name: "24c-panel-narrow", size: CGSize(width: 860, height: 640), store: { running(panel: true) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
            }),
            Scene(name: "24d-panel-connections", store: {
                let store = running(page: .connections, panel: true)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                store.suggestions = [Suggestion(kind: .failing(host: "chatgpt.com", count: 3))]
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }),
            // In full screen the system moves the toolbar to a window of its own, over this one.
            Scene(name: "25-fullscreen-connections-panel", store: {
                let store = sample()
                store.page = .connections
                store.agentPanel = true
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }, fullScreen: true),
            Scene(name: "25b-fullscreen-proxies", store: { running(page: .proxies) }, view: AnyView(MainView()), fullScreen: true),
            Scene(name: "09e-connections", store: {
                let store = running(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09k-add-rule", size: CGSize(width: 480, height: 420), store: { running(page: .connections) },
                  view: AnyView(AddRuleSheet(row: sampleConnections()[0]))),
            Scene(name: "09g-route-map", size: CGSize(width: 260, height: 620), store: { running(page: .connections) },
                  view: AnyView(RouteMap(row: sampleConnections()[0]) { RouteActions(row: sampleConnections()[0], addRule: {}, close: {}) })),
            // One selected row: its route and actions beside the table.
            Scene(name: "09m-connections-selected", store: {
                let store = running(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                return store
            }, view: AnyView(ConnectionsView(selection: [sampleSelectedConnection])
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            Scene(name: "09h-requests", store: {
                let store = running(page: .requests)
                store.requests = sampleConnections().enumerated().map { ClosedRequest(row: $1, closedAt: .now.addingTimeInterval(-Double($0) * 7)) }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09i-dns", store: { running(page: .dns) }, view: AnyView(MainView())),
            Scene(name: "04b-overview-suggestions", store: {
                let store = running()
                store.suggestions = [Suggestion(kind: .failing(host: "chatgpt.com", count: 4)),
                                     Suggestion(kind: .slowNode(group: "节点选择", node: "🇺🇸 美国 洛杉矶 01"))]
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09f-logs", store: {
                let store = running(page: .logs)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(MainView())),
            // A level with no entries, which must keep the way back to the others.
            Scene(name: "09l-logs-empty-level", store: {
                let store = running(page: .logs)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(LogsView(level: .debug).background(Color.surface))),
            Scene(name: "10-import", size: CGSize(width: 560, height: 360), store: {
                let store = sample()
                store.importText = "https://sub.example.invalid/api/v1/client/subscribe?token=demo"
                store.importError = String(localized: "找不到这个配置的文件，可能已被删除。")
                return store
            }, view: AnyView(ImportSheet())),
            Scene(name: "11-profile-nodes", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .nodes))),
            Scene(name: "12-profile-routing", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .routing))),
            Scene(name: "13-settings-general", size: CGSize(width: 520, height: 360), store: { sample() }, view: AnyView(GeneralSettings())),
            Scene(name: "14-settings-proxy", size: CGSize(width: 520, height: 300), store: { sample() }, view: AnyView(ProxySettings())),
            Scene(name: "15-overview-tun", store: { running(tun: true) }, view: AnyView(MainView())),
            Scene(name: "18-proxies-map", size: CGSize(width: 900, height: 520), store: { running(page: .proxies) }, view: AnyView(NodeMapView())),
            Scene(name: "18b-proxies-map-page", store: { running(page: .proxies) }, view: AnyView(NodeMapView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // Beside the Agent panel in the smallest window.
            Scene(name: "18c-proxies-map-narrow", size: CGSize(width: 480, height: 640), store: { running(page: .proxies) }, view: AnyView(NodeMapView().background(Color.surface))),
            Scene(name: "18d-proxies-map-search", store: { running(page: .proxies) }, view: AnyView(NodeMapView(query: "大阪").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // Every shade, a crowded Europe, a region with no shape, and nodes with no region.
            Scene(name: "18e-proxies-map-many", store: {
                let store = running(page: .proxies)
                typealias Member = ProxyStore.Group.Member
                let counts = [("🇺🇸 美国", 12), ("🇯🇵 日本", 5), ("🇩🇪 德国", 4), ("🇫🇷 法国", 2), ("🇬🇧 英国", 1), ("🇳🇱 荷兰", 1), ("🇭🇰 香港", 8), ("🇹🇼 台湾", 3), ("🇸🇬 新加坡", 4)]
                var members = counts.flatMap { place, count in
                    (1...count).map { Member(name: "\(place) \($0)", delay: place.contains("德国") || place.contains("法国") ? 260 : 90 + $0 * 7, isGroup: false) }
                }
                members += [Member(name: "Relay Alpha", delay: 120, isGroup: false), Member(name: "Relay Beta", delay: nil, isGroup: false)]
                store.groups = [.init(name: "节点选择", type: "Selector", now: "🇺🇸 美国 1", members: members)]
                return store
            }, view: AnyView(NodeMapView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // The whole window with the map chosen, on throwaway defaults, for the toolbar's switch.
            Scene(name: "18f-proxies-map-window", store: { running(page: .proxies) }, view: AnyView(MainView().defaultAppStorage(mapDefaults()))),
            Scene(name: "18g-proxies-map-window-smallest", size: CGSize(width: 960, height: 640), store: {
                let store = running(page: .proxies)
                store.agentPanel = true
                return store
            }, view: AnyView(MainView().defaultAppStorage(mapDefaults()))),
            Scene(name: "19-profiles-update-failed", store: {
                let store = running(page: .proxies)
                if var first = store.profiles.first {
                    first.updateError = String(localized: "无法下载订阅：网络错误或超时。")
                    first.usage?.expire = .now.addingTimeInterval(2 * 86_400)
                    store.profiles[0] = first
                }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "21-profile-check", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .check))),
            Scene(name: "22-settings-shortcuts", size: CGSize(width: 560, height: 320), store: { sample() }, view: AnyView(HotKeySettings())),
            Scene(name: "23-settings-about", size: CGSize(width: 560, height: 320), store: { sample() }, view: AnyView(AboutSettings())),
            Scene(name: "20-profile-template", size: CGSize(width: 560, height: 520), store: {
                let store = sample()
                if let id = store.profiles.first?.id { store.setTemplate(RuleTemplate.standard, for: id) }
                return store
            }, view: AnyView(SampleProfileSheet(tab: .routing))),
            Scene(name: "16-settings-tun-approval", size: CGSize(width: 560, height: 460), store: {
                let store = sample()
                store.settings.tun = true
                store.helperProbe = { .needsApproval }
                store.notice = String(localized: "TUN 未能启动，已改用系统代理。\(String(localized: "需要在系统设置的“登录项”中允许 Veer 的后台服务。"))")
                return store
            }, view: AnyView(TUNSettings())),
            Scene(name: "17-settings-tun-ready", size: CGSize(width: 560, height: 420), store: {
                let store = sample()
                store.settings.tun = true
                store.helperProbe = { .ready }
                return store
            }, view: AnyView(TUNSettings())),
        ]
    }

    static func sampleConnections() -> [ConnectionRow] {
        typealias Connection = MihomoController.Connection
        let now = Date()
        let rows: [(String, String?, String, String, [String], Int64, Int64, Int64, TimeInterval)] = [
            ("www.youtube.com", "Google Chrome", "RuleSet", "youtube", ["🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", "节点选择"], 182_000, 48_300_000, 2_400_000, 95),
            ("api.github.com", "git", "DomainSuffix", "github.com", ["🇭🇰 香港 01", "自动选择", "节点选择"], 3_200, 21_000, 0, 12),
            ("chatgpt.com", "Safari", "RuleSet", "openai", ["🇺🇸 美国 洛杉矶 01", "节点选择"], 64_000, 1_250_000, 31_000, 340),
            ("www.apple.com", "Safari", "DomainSuffix", "apple.com", ["DIRECT"], 1_800, 9_400, 0, 4),
            ("api.telegram.org", "Telegram", "RuleSet", "telegram", ["🇸🇬 新加坡 01", "节点选择"], 22_000, 18_000, 120, 1_830),
            ("149.154.167.51:443", "Telegram", "Match", "", ["🇸🇬 新加坡 01", "节点选择"], 4_000, 2_000, 0, 60),
        ]
        return rows.enumerated().map { index, row in
            let connection = Connection(id: "c\(index)", metadata: .init(network: "tcp", host: row.0.contains(":") ? "" : row.0,
                                                                        destinationIP: row.0.contains(":") ? "149.154.167.51" : nil,
                                                                        destinationPort: "443", process: row.1),
                                        chains: row.4, rule: row.2, rulePayload: row.3, upload: row.5, download: row.6,
                                        start: now.addingTimeInterval(-row.8))
            return ConnectionRow(connection, uploadRate: row.7 / 20, downloadRate: row.7)
        }
    }

    static var sampleSelectedConnection: ConnectionRow.ID { sampleConnections()[0].id }

    static func sampleLogs() -> [LogEntry] {
        [
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52344(Google Chrome) --> www.youtube.com:443 match RuleSet(youtube) using 节点选择[🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路]"),
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52350(git) --> api.github.com:443 match DomainSuffix(github.com) using 节点选择[🇭🇰 香港 01]"),
            LogEntry(level: "warning", message: "[TCP] dial 节点选择 (match RuleSet/openai) 127.0.0.1:52361(Safari) --> chatgpt.com:443 error: i/o timeout"),
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52370(Safari) --> www.apple.com:443 match DomainSuffix(apple.com) using DIRECT"),
            LogEntry(level: "error", message: "[Provider] reject-list pull error: Get \"https://cdn.jsdelivr.net/…\": context deadline exceeded"),
            LogEntry(level: "info", message: "[UDP] 127.0.0.1:61502(Google Chrome) --> www.youtube.com:443 match AND((NETWORK,UDP),(DST-PORT,443)) using REJECT"),
        ]
    }

    /// A conversation about the sample profile with one proposal: Netflix to the Japan node.
    static func sampleThread(_ agent: AgentStore, status: Turn.ProposalStatus) {
        guard let profile = agent.proxy.activeProfile, let text = try? agent.proxy.effectiveText(of: profile.id),
              let document = try? ConfigDocument.parse(text), let target = document.target(named: "🇯🇵 日本 大阪 02") else { return }
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: target.id),
                                         .route(matchType: "DOMAIN-SUFFIX", match: "nflxvideo.net", targetId: target.id)])
        guard let result = try? PlanApplier.apply(plan, to: document) else { return }
        var session = Session(title: "Netflix 走日本", source: .pasted, text: text)
        session.profileID = profile.id
        session.exitsConfirmed = true
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .done) }
        var turn = Turn(prompt: "Netflix 走日本", mode: .ai(model: "qwen3:14b"), steps: steps, outcome: .proposal(.init(
            plan: plan, items: result.items, accepted: Set(result.items.map(\.id)), baseDraft: text, candidate: result.candidate,
            validation: ValidationResult(status: .passed, message: String(localized: "Mihomo 校验通过")), status: status)))
        turn.understanding = "把 Netflix 的流量交给日本节点"
        turn.duration = 3.2
        session.turns = [turn]
        agent.sessions = [session]
        agent.selectedID = session.id
    }

    /// The node sheet for the sample's first profile.
    struct SampleProfileSheet: View {
        @Environment(ProxyStore.self) private var store
        let tab: ProfileDetailSheet.Tab

        var body: some View {
            if let profile = store.profiles.first { ProfileDetailSheet(profile: profile, tab: tab) }
        }
    }

    static let sampleConfig = """
    proxies:
      - {name: 🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 日本 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇭🇰 香港 01, type: ss, server: hk1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 美国 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇸🇬 新加坡 01, type: ss, server: sg1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 节点选择, type: select, proxies: [🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路, 🇯🇵 日本 大阪 02, 🇭🇰 香港 01, 🇺🇸 美国 洛杉矶 01, 🇸🇬 新加坡 01]}
    rules:
      - MATCH,节点选择
    """

    static func sample(profiles: Bool = true) -> ProxyStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-snapshot-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!
        // Scenes that want the Agent panel say so.
        defaults.set(false, forKey: "agentPanel")
        let paths = VeerPaths(root: root)
        if profiles {
            let hour: TimeInterval = 3600
            let store = ProfileStore(paths: paths, secrets: FileKeyStore(url: paths.secrets))
            try? store.save(Profile(name: "我的机场 · 高速专线（这是一个很长的订阅名称，用来检查截断）", isSubscription: true,
                                    updatedAt: .now.addingTimeInterval(-2 * hour), nodeCount: 5,
                                    usage: SubscriptionUsage(upload: 3 << 30, download: 57 << 30, total: 200 << 30, expire: nil)), text: sampleConfig)
            try? store.save(Profile(name: "家里的路由器", isSubscription: false, updatedAt: .now.addingTimeInterval(-30 * 24 * hour), nodeCount: 3),
                            text: sampleConfig)
            if let first = store.loadAll().first {
                try? RoutingStore(paths: paths).save(RoutingLayer(excludedNodes: ["🇸🇬 新加坡 01"]), for: first.id)
            }
        }
        return ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in "" }), binary: nil, defaults: defaults)
    }

    static func failed(page: Page) -> ProxyStore {
        let store = sample()
        store.page = page
        store.phase = .failed(String(localized: "端口 \(String(7890)) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。"), log: [
            "time=\"2026-10-29T10:00:00+08:00\" level=info msg=\"Start initial configuration in progress\"",
            "level=error msg=\"Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use\"",
        ])
        return store
    }

    static func running(page: Page = .overview, tun: Bool = false, panel: Bool = false, lan: Bool = false) -> ProxyStore {
        let store = sample()
        store.agentPanel = panel
        // Before the phase: turning TUN on in a running store restarts the core.
        store.settings.tun = tun
        store.settings.allowLAN = lan
        store.tunActive = tun
        store.page = page
        store.phase = .running
        store.systemProxyOn = true
        store.exit = ExitInfo(ip: "203.0.113.7", country: "Japan", countryCode: "JP", organization: "DATAWAVE GLOBAL LLC")
        store.runningSince = .now.addingTimeInterval(-600)
        store.uploadRate = 42 << 10
        store.downloadRate = 3 << 20
        typealias Member = ProxyStore.Group.Member
        store.groups = [
            .init(name: "节点选择", type: "Selector", now: "🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", members: [
                Member(name: "自动选择", delay: 86, isGroup: true),
                Member(name: "🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", delay: 92, isGroup: false),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
                Member(name: "🇭🇰 香港 01", delay: 38, isGroup: false),
                Member(name: "🇺🇸 美国 洛杉矶 01", delay: 0, isGroup: false),
                Member(name: "🇸🇬 新加坡 01", delay: nil, isGroup: false),
                Member(name: "DIRECT", delay: nil, isGroup: false),
            ]),
            .init(name: "自动选择", type: "URLTest", now: "🇭🇰 香港 01", members: [
                Member(name: "🇭🇰 香港 01", delay: 38, isGroup: false),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
                Member(name: "🇺🇸 美国 洛杉矶 01", delay: 1260, isGroup: false),
            ]),
            .init(name: "Netflix", type: "Selector", now: "🇯🇵 日本 大阪 02", members: [
                Member(name: "节点选择", delay: nil, isGroup: true),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
            ]),
        ]
        return store
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Into full screen and out again, with a picture of everything this app shows in between: the
    /// toolbar's own full-screen window is above `window`, so capturing that alone would leave it out.
    static func captureFullScreen(_ window: NSWindow, to url: URL) async {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        // Core Graphics counts from the top of the main screen. optionOnScreenAboveWindow = 1 << 1,
        // optionIncludingWindow = 1 << 3, bestResolution = 1 << 3.
        let flipped = (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY
        let bounds = CGRect(x: window.frame.minX, y: flipped, width: window.frame.width, height: window.frame.height)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            if let image = function(bounds, (1 << 1) | (1 << 3), UInt32(window.windowNumber), 1 << 3)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        // What covers what, for a check that does not depend on reading the picture.
        let layout = NSApp.windows.filter(\.isVisible).map { shown in
            "\(type(of: shown)) \(shown.frame) level \(shown.level.rawValue) toolbar \(shown.toolbar?.isVisible.description ?? "none")"
                + " mouse \(!shown.ignoresMouseEvents) alpha \(shown.alphaValue) opaque \(shown.isOpaque) number \(shown.windowNumber)"
        }
        let top = NSWindow.windowNumber(at: CGPoint(x: window.frame.maxX - 60, y: window.frame.maxY - 20), belowWindowWithWindowNumber: 0)
        let notes = url.deletingPathExtension().appendingPathExtension("txt")
        try? (["content \(window.contentLayoutRect)", "frontmost in the row \(top), this window \(window.windowNumber)"] + layout).joined(separator: "\n")
            .write(to: notes, atomically: true, encoding: .utf8)
        // ⌘F finds the field by where it is in the window, which full screen changes.
        ToolbarSearchFocus.focus()
        let searching = "search field focused \(window.firstResponder is NSTextView)"
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        // And the toolbar is back for the ordinary window.
        let after = "after leaving: toolbar \(window.toolbar?.isVisible.description ?? "none"), content \(window.contentLayoutRect)"
        let layoutNotes = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        try? [searching, after, layoutNotes].joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
        capture(window, to: url.deletingPathExtension().appendingPathExtension("left.png"))
    }

    /// The window as the screen shows it (sidebar material included); falls back to drawing the
    /// view hierarchy, which leaves vibrancy out.
    static func capture(_ window: NSWindow, to url: URL) {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // optionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
            if let image = function(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
