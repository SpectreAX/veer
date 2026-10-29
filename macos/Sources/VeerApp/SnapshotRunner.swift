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
        Task { @MainActor in
            for appearance in appearances {
                let name = appearance == "dark" ? NSAppearance.Name.darkAqua : .aqua
                for scene in scenes() {
                    let store = scene.store()
                    let agent = AgentStore(proxy: store, keyStore: FileKeyStore(url: store.paths.secrets),
                                           defaults: UserDefaults(suiteName: "veer-snapshot-agent-\(UUID().uuidString)")!, persist: false)
                    scene.agent?(agent)
                    // The app's window never gets smaller than this; content sized views would shrink it.
                    let view = scene.view.environment(store).environment(agent).tint(.veerAccent).frame(width: scene.size.width, height: scene.size.height)
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: scene.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: name)
                    window.contentViewController = NSHostingController(rootView: view)
                    window.setContentSize(scene.size)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    try? await Task.sleep(for: .milliseconds(700))
                    capture(window, to: directory.appendingPathComponent("\(scene.name)-\(appearance).png"))
                    window.orderOut(nil)
                }
            }
            NSApp.terminate(nil)
        }
    }

    struct Scene {
        let name: String
        var size = CGSize(width: 1080, height: 720)
        let store: () -> ProxyStore
        let view: AnyView
        /// Fills the Agent page's state, for its scenes.
        var agent: ((AgentStore) -> Void)? = nil
    }

    static func scenes() -> [Scene] {
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
            Scene(name: "06-profiles", store: { running(page: .profiles) }, view: AnyView(MainView())),
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
            Scene(name: "09d-agent-applied", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }),
            Scene(name: "09e-connections", store: {
                let store = running(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09f-logs", store: {
                let store = running(page: .logs)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(MainView())),
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

    static func running(page: Page = .overview) -> ProxyStore {
        let store = sample()
        store.page = page
        store.phase = .running
        store.systemProxyOn = true
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
