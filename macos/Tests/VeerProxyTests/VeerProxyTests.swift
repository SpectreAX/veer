import Foundation
import Testing
import VeerCore
import Yams
@testable import VeerProxy

struct RuntimeConfigTests {
    static let profile = """
    port: 7890
    socks-port: 7891
    mixed-port: 7892
    allow-lan: true
    external-controller: 0.0.0.0:9090
    external-ui: ui
    secret: old
    tun: {enable: true, stack: system}
    dns: {enable: true, listen: 0.0.0.0:53, nameserver: [223.5.5.5]}
    proxies:
      - {name: 🇯🇵 日本 01, type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 节点选择, type: select, proxies: [🇯🇵 日本 01]}
    rules:
      - MATCH,节点选择
    """

    @Test func veerOwnsPortsControllerAndTun() throws {
        let yaml = try RuntimeConfig.build(profile: Self.profile, settings: RuntimeSettings(mixedPort: 7899), controllerPort: 51234, secret: "s3cret")
        let config = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect(config["mixed-port"] as? Int == 7899)
        #expect(config["allow-lan"] as? Bool == false)
        #expect(config["external-controller"] as? String == "127.0.0.1:51234")
        #expect(config["secret"] as? String == "s3cret")
        for key in ["port", "socks-port", "external-ui", "tun"] { #expect(config[key] == nil, "\(key)") }
        // Everything else stays as the profile wrote it, names included.
        let dns = try #require(config["dns"] as? [String: Any])
        #expect(dns["enable"] as? Bool == true && dns["listen"] == nil && (dns["nameserver"] as? [String]) == ["223.5.5.5"])
        #expect(((config["geox-url"] as? [String: String])?["mmdb"])?.contains("jsdelivr") == true)
        #expect(((config["proxies"] as? [[String: Any]])?.first?["name"] as? String) == "🇯🇵 日本 01")
        print(yaml.split(separator: "\n").first { $0.contains("name") } ?? "")
        #expect((config["rules"] as? [String]) == ["MATCH,节点选择"])
        #expect(((config["profile"] as? [String: Any])?["store-selected"] as? Bool) == true)
    }

    @Test func aProfilesOwnGeodataSourceIsKept() throws {
        let yaml = try RuntimeConfig.build(profile: "geox-url: {mmdb: https://mirror.example/country.mmdb}\nrules: [MATCH,DIRECT]", settings: .init(), controllerPort: 1, secret: "x")
        let config = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect((config["geox-url"] as? [String: String]) == ["mmdb": "https://mirror.example/country.mmdb"])
    }

    @Test func aProfileThatIsNotAMappingIsRefused() {
        #expect(throws: EditorError.self) { try RuntimeConfig.build(profile: "- a\n- b", settings: .init(), controllerPort: 1, secret: "x") }
    }

    @Test func secretsAreRandom() {
        #expect(RuntimeConfig.makeSecret().count == 32)
        #expect(RuntimeConfig.makeSecret() != RuntimeConfig.makeSecret())
    }
}

struct SystemProxyTests {
    /// Answers like networksetup on a Mac with Wi-Fi, Ethernet and a disabled Thunderbolt Bridge.
    final class FakeNetworkSetup: @unchecked Sendable {
        var calls: [[String]] = []
        var webProxy: [String: String] = ["Wi-Fi": "Enabled: No\nServer: \nPort: 0", "Ethernet": "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890"]
        let lock = NSLock()
        var runner: SystemProxy.Runner {
            { arguments in
                self.lock.withLock {
                    self.calls.append(arguments)
                    switch arguments.first {
                    case "-listallnetworkservices": return "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nEthernet\n*Thunderbolt Bridge\n"
                    case "-getwebproxy": return self.webProxy[arguments[1]] ?? ""
                    default: return ""
                    }
                }
            }
        }
    }

    @Test func enableSetsEveryEnabledService() throws {
        let fake = FakeNetworkSetup()
        try SystemProxy(runner: fake.runner).enable(host: "127.0.0.1", port: 7890)
        let set = fake.calls.filter { $0.first == "-setwebproxy" }.map { $0[1] }
        #expect(set == ["Wi-Fi", "Ethernet"])
        #expect(fake.calls.contains(["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "7890"]))
        #expect(fake.calls.contains { $0.first == "-setproxybypassdomains" && $0.contains("*.local") })
    }

    @Test func disableLeavesAnotherAppsProxyAlone() throws {
        let fake = FakeNetworkSetup()
        fake.webProxy["Wi-Fi"] = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7897"
        let proxy = SystemProxy(runner: fake.runner)
        #expect(try proxy.isEnabled(host: "127.0.0.1", port: 7890))
        try proxy.disable(host: "127.0.0.1", port: 7890)
        let turnedOff = fake.calls.filter { $0.first == "-setwebproxystate" }
        #expect(turnedOff == [["-setwebproxystate", "Ethernet", "off"]])
    }
}

struct ProfileStoreTests {
    final class MemoryKeys: KeyStoring, @unchecked Sendable {
        var keys: [String: String] = [:]
        func read(for provider: String) -> String? { keys[provider] }
        func save(_ key: String, for provider: String) throws { keys[provider] = key }
        func delete(for provider: String) { keys[provider] = nil }
    }

    @Test func profilesRoundTripAndLinksStayOutOfTheIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryKeys()
        let store = ProfileStore(paths: VeerPaths(root: root), secrets: keys)
        // The index keeps whole seconds.
        let profile = Profile(name: "机场", isSubscription: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), nodeCount: 3)
        try store.save(profile, text: "proxies: []\n")
        try store.setSubscriptionURL(URL(string: "https://sub.example.invalid/x?token=t")!, for: profile.id)

        let reloaded = ProfileStore(paths: VeerPaths(root: root), secrets: keys)
        #expect(reloaded.loadAll() == [profile])
        #expect(try reloaded.text(of: profile.id) == "proxies: []\n")
        #expect(reloaded.subscriptionURL(of: profile.id)?.query == "token=t")
        let index = try String(contentsOf: VeerPaths(root: root).profileIndex, encoding: .utf8)
        #expect(!index.contains("token"))

        reloaded.delete(profile.id)
        #expect(reloaded.loadAll().isEmpty && keys.keys.isEmpty)
        #expect(throws: EditorError.self) { try reloaded.text(of: profile.id) }
    }
}

/// Runs the real core: needs `VEER_MIHOMO_BIN`, or `vendor/mihomo` from scripts/build-mihomo.sh.
struct CoreProcessTests {
    static let binary: URL? = {
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/mihomo").path
        let candidates = [ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"], local].compactMap { $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    @Test(.enabled(if: CoreProcessTests.binary != nil)) func startsServesAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VeerPaths(root: root)
        try paths.prepare()
        let port = try #require(Ports.free()), mixed = try #require(Ports.free())
        let secret = RuntimeConfig.makeSecret()
        let yaml = try RuntimeConfig.build(profile: RuntimeConfigTests.profile, settings: RuntimeSettings(mixedPort: mixed), controllerPort: port, secret: secret)
        try yaml.write(to: paths.runtimeConfig, atomically: true, encoding: .utf8)

        let core = CoreProcess(binary: try #require(Self.binary), home: paths.core)
        try core.start(config: paths.runtimeConfig) { status, tail in Issue.record("core exited \(status): \(tail.suffix(5))") }
        defer { core.stop() }
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
        var version: String?
        for _ in 0..<100 where version == nil {
            version = try? await controller.version()
            if version == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(version != nil)
        #expect(Ports.inUse(mixed))
        let proxies = try await controller.proxies()
        #expect(proxies["节点选择"]?.now == "🇯🇵 日本 01")
        try await controller.setMode("direct")
        #expect(try await controller.mode() == "direct")
        core.stop()
        #expect(!core.isRunning && !Ports.inUse(mixed))
    }
}
