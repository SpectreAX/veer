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
                    // The app's window never gets smaller than this; content sized views would shrink it.
                    let view = scene.view.environment(store).tint(.veerAccent).frame(width: scene.size.width, height: scene.size.height)
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
            Scene(name: "09-agent-later", store: { running(page: .agent) }, view: AnyView(MainView())),
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
