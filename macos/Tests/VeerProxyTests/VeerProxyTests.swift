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

struct ProxySnapshotTests {
    /// Wi-Fi had the user's own proxy and bypass list; Ethernet had none.
    final class FakeServices: @unchecked Sendable {
        var calls: [[String]] = []
        var services = ["Wi-Fi", "Ethernet"]
        var answers: [String: String] = [
            "-getwebproxy Wi-Fi": "Enabled: Yes\nServer: proxy.corp.example\nPort: 3128\nAuthenticated Proxy Enabled: 0",
            "-getsecurewebproxy Wi-Fi": "Enabled: No\nServer: proxy.corp.example\nPort: 3128\nAuthenticated Proxy Enabled: 0",
            "-getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0",
            "-getproxybypassdomains Wi-Fi": "*.corp.example\nlocalhost\n",
            "-getwebproxy Ethernet": "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0",
            "-getsecurewebproxy Ethernet": "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0",
            "-getsocksfirewallproxy Ethernet": "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0",
            "-getproxybypassdomains Ethernet": "There aren't any bypass domains set on Ethernet.\n",
        ]
        let lock = NSLock()
        var runner: SystemProxy.Runner {
            { arguments in
                self.lock.withLock {
                    self.calls.append(arguments)
                    if arguments.first == "-listallnetworkservices" { return "An asterisk (*) denotes that a network service is disabled.\n" + self.services.joined(separator: "\n") }
                    return self.answers[arguments.prefix(2).joined(separator: " ")] ?? ""
                }
            }
        }
    }

    @Test func aSnapshotRecordsEachProxyAndBypassList() throws {
        let fake = FakeServices()
        let snapshot = try SystemProxy(runner: fake.runner).snapshot()
        #expect(snapshot.services.map(\.name) == ["Wi-Fi", "Ethernet"])
        let wifi = snapshot.services[0]
        #expect(wifi.web == .init(enabled: true, server: "proxy.corp.example", port: 3128))
        #expect(wifi.secure.enabled == false && wifi.socks.server.isEmpty)
        #expect(wifi.bypass == ["*.corp.example", "localhost"] && snapshot.services[1].bypass.isEmpty)
    }

    @Test func restoringPutsTheUsersProxyBack() throws {
        let fake = FakeServices()
        let proxy = SystemProxy(runner: fake.runner)
        let snapshot = try proxy.snapshot()
        fake.calls = []
        try proxy.restore(snapshot, host: "127.0.0.1", port: 7890)
        #expect(fake.calls.contains(["-setwebproxy", "Wi-Fi", "proxy.corp.example", "3128"]))
        #expect(fake.calls.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
        #expect(fake.calls.contains(["-setproxybypassdomains", "Wi-Fi", "*.corp.example", "localhost"]))
        #expect(fake.calls.contains(["-setwebproxystate", "Ethernet", "off"]))
        #expect(fake.calls.contains(["-setproxybypassdomains", "Ethernet", ""]))
    }

    @Test func aRecordedVeerProxyComesBackOffAndUnknownServicesOnlyLoseVeers() throws {
        let fake = FakeServices()
        fake.answers["-getwebproxy Wi-Fi"] = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890"
        let proxy = SystemProxy(runner: fake.runner)
        let snapshot = try proxy.snapshot(services: ["Wi-Fi"])
        fake.answers["-getwebproxy Ethernet"] = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890"
        fake.calls = []
        try proxy.restore(snapshot, host: "127.0.0.1", port: 7890)
        #expect(!fake.calls.contains { $0.first == "-setwebproxy" })
        #expect(fake.calls.contains(["-setwebproxystate", "Wi-Fi", "off"]))
        #expect(fake.calls.contains(["-setsocksfirewallproxystate", "Ethernet", "off"]))
        #expect(!fake.calls.contains { $0.first == "-setproxybypassdomains" && $0[1] == "Ethernet" })
    }

    @Test func mergingKeepsTheFirstRecordOfAService() throws {
        let fake = FakeServices()
        var snapshot = try SystemProxy(runner: fake.runner).snapshot(services: ["Wi-Fi"])
        let later = try SystemProxy(runner: fake.runner).snapshot()
        snapshot.services[0].bypass = ["kept"]
        snapshot.merge(later)
        #expect(snapshot.services.map(\.name) == ["Wi-Fi", "Ethernet"] && snapshot.services[0].bypass == ["kept"])
    }

    @Test func stateRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(paths: VeerPaths(root: root))
        #expect(store.load() == ProxyState())
        var state = ProxyState()
        state.running = true
        state.mode = "global"
        state.systemProxy = true
        state.proxyPort = 7890
        state.snapshot = try SystemProxy(runner: FakeServices().runner).snapshot()
        store.save(state)
        #expect(StateStore(paths: VeerPaths(root: root)).load() == state)
    }
}

struct RuntimeOverrideTests {
    static func config(_ settings: RuntimeSettings, profile: String = RuntimeConfigTests.profile) throws -> [String: Any] {
        let yaml = try RuntimeConfig.build(profile: profile, settings: settings, controllerPort: 1, secret: "s")
        return try #require(try Yams.load(yaml: yaml) as? [String: Any])
    }

    @Test func ipv6AndProcessMatchingFollowSettings() throws {
        var settings = RuntimeSettings()
        #expect(try Self.config(settings)["ipv6"] as? Bool == false)
        #expect(try Self.config(settings)["find-process-mode"] as? String == "always")
        settings.ipv6 = true
        settings.processMatching = false
        #expect(try Self.config(settings)["ipv6"] as? Bool == true)
        #expect(try Self.config(settings)["find-process-mode"] as? String == "off")
    }

    @Test func disablingQUICPutsOneRejectRuleFirst() throws {
        var settings = RuntimeSettings()
        #expect(try (Self.config(settings)["rules"] as? [String]) == ["MATCH,节点选择"])
        settings.disableQUIC = true
        let rules = try #require(try Self.config(settings)["rules"] as? [String])
        #expect(rules == [RuntimeConfig.quicRule, "MATCH,节点选择"])
        // Building on a config that already has it does not add a second one.
        let again = try RuntimeConfig.build(profile: RuntimeConfig.build(profile: RuntimeConfigTests.profile, settings: settings, controllerPort: 1, secret: "s"),
                                            settings: settings, controllerPort: 1, secret: "s")
        #expect((try Yams.load(yaml: again) as? [String: Any])?["rules"] as? [String] == rules)
    }

    @Test func aProfilesOwnDNSWinsUnlessTheUserSaysOtherwise() throws {
        var settings = RuntimeSettings()
        let own = try #require(try Self.config(settings)["dns"] as? [String: Any])
        #expect(own["nameserver"] as? [String] == ["223.5.5.5"] && own["listen"] == nil)
        settings.preferProfileDNS = false
        let veer = try #require(try Self.config(settings)["dns"] as? [String: Any])
        #expect(veer["nameserver"] as? [String] == RuntimeSettings.defaultDNSServers)
        #expect(veer["enhanced-mode"] as? String == "fake-ip" && (veer["fake-ip-filter"] as? [String])?.contains("+.push.apple.com") == true)
    }

    @Test func profilesWithoutDNSGetVeersAndRedirHostHasNoFakeRange() throws {
        var settings = RuntimeSettings()
        settings.dnsMode = .redirHost
        settings.dnsServers = ["https://1.1.1.1/dns-query"]
        let dns = try #require(try Self.config(settings, profile: "rules: [MATCH,DIRECT]")["dns"] as? [String: Any])
        #expect(dns["enhanced-mode"] as? String == "redir-host" && dns["fake-ip-range"] == nil)
        #expect(dns["proxy-server-nameserver"] as? [String] == ["https://1.1.1.1/dns-query"])
    }

    @Test func settingsSavedBeforeTheNewFieldsStillLoad() throws {
        let old = try JSONDecoder().decode(RuntimeSettings.self, from: Data(#"{"mixedPort":7899,"allowLAN":true,"logLevel":"debug"}"#.utf8))
        #expect(old.mixedPort == 7899 && old.allowLAN && old.logLevel == "debug")
        #expect(old.processMatching && !old.disableQUIC && old.dnsMode == .fakeIP && old.preferProfileDNS)
    }

    @Test(.enabled(if: CoreProcessTests.binary != nil)) func everyOverridePassesMihomo() async throws {
        var settings = RuntimeSettings()
        settings.ipv6 = true
        settings.disableQUIC = true
        settings.preferProfileDNS = false
        let yaml = try RuntimeConfig.build(profile: RuntimeConfigTests.profile, settings: settings, controllerPort: 1, secret: "s")
        #expect(await MihomoValidator(binary: CoreProcessTests.binary).validate(yaml).status == .passed)
    }
}

/// The faster build keeps the profile's sections as written; it must mean the same as parsing.
struct FastBuildTests {
    static let profiles = [
        RuntimeConfigTests.profile,
        // Comments, quoted keys, block-style rules, a dns section with a listener, emoji.
        """
        # From a subscription
        'mixed-port': 7892
        dns:
          enable: true
          listen: 0.0.0.0:1053
          nameserver: [https://1.1.1.1/dns-query]
        proxies:
          - name: "🇯🇵 东京 01"
            type: ss
            server: jp.example.invalid
            port: 1
            cipher: aes-128-gcm
            password: "p"
        proxy-groups:
          - {name: 节点选择, type: select, proxies: [🇯🇵 东京 01, DIRECT]}
        rules:
          # Ads first
          - DOMAIN-SUFFIX,ads.example,REJECT
          - MATCH,节点选择
        """,
        "rules: [MATCH,DIRECT]",
        "proxies: []\nrules:\n- MATCH,DIRECT\n",
    ]

    static func load(_ yaml: String) throws -> NSDictionary {
        try #require(try Yams.load(yaml: yaml) as? NSDictionary)
    }

    @Test(arguments: [false, true]) func keepingSectionsMeansTheSameAsParsing(quicOff: Bool) throws {
        var settings = RuntimeSettings()
        settings.disableQUIC = !quicOff
        for (index, profile) in Self.profiles.enumerated() {
            for preferProfileDNS in [true, false] {
                settings.preferProfileDNS = preferProfileDNS
                if settings.disableQUIC && profile.hasPrefix("rules: [") {
                    // Flow-style rules: the QUIC rule needs the full parse.
                    #expect(try RuntimeConfig.buildKeepingSections(profile: profile, settings: settings, controllerPort: 1, secret: "s") == nil)
                    continue
                }
                let fast = try #require(try RuntimeConfig.buildKeepingSections(profile: profile, settings: settings, controllerPort: 1, secret: "s"),
                                        "profile \(index) fell back")
                let parsed = try RuntimeConfig.buildByParsing(profile: profile, settings: settings, controllerPort: 1, secret: "s")
                #expect(try Self.load(fast) == Self.load(parsed), "profile \(index), quic \(!quicOff), profile dns \(preferProfileDNS)")
            }
        }
    }

    @Test func textItCannotCutSafelyFallsBack() throws {
        let anchors = "base: &base {type: ss}\nproxies:\n  - {<<: *base, name: a}\nrules: [MATCH,DIRECT]"
        var quic = RuntimeSettings()
        quic.disableQUIC = true
        #expect(try RuntimeConfig.buildKeepingSections(profile: anchors, settings: .init(), controllerPort: 1, secret: "s") == nil)
        #expect(try RuntimeConfig.buildKeepingSections(profile: "{rules: [MATCH,DIRECT]}", settings: .init(), controllerPort: 1, secret: "s") == nil)
        // Flow-style rules cannot take a QUIC rule by text.
        #expect(try RuntimeConfig.buildKeepingSections(profile: "rules: [MATCH,DIRECT]", settings: quic, controllerPort: 1, secret: "s") == nil)
        // A wildcard is not an alias.
        #expect(try RuntimeConfig.buildKeepingSections(profile: "dns:\n  fake-ip-filter:\n    - '*.lan'\n    - \"+.local\"\nrules: [MATCH,DIRECT]",
                                                       settings: .init(), controllerPort: 1, secret: "s") != nil)
        // Both still build, through the full parse.
        #expect(try Self.load(RuntimeConfig.build(profile: anchors, settings: .init(), controllerPort: 1, secret: "s"))["proxies"] != nil)
    }

    @Test(.enabled(if: CoreProcessTests.binary != nil)) func theKeptTextPassesMihomo() async throws {
        var settings = RuntimeSettings()
        settings.disableQUIC = true
        let yaml = try #require(try RuntimeConfig.buildKeepingSections(profile: Self.profiles[1], settings: settings, controllerPort: 1, secret: "s"))
        #expect(yaml.contains("🇯🇵 东京 01") && !yaml.contains("\\U0001F1"))
        #expect(await MihomoValidator(binary: CoreProcessTests.binary).validate(yaml).status == .passed)
    }
}
