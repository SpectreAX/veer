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

struct TUNConfigTests {
    @Test func tunIsOffUnlessAskedAndAProfilesOwnIsDropped() throws {
        let config = try RuntimeOverrideTests.config(RuntimeSettings())
        #expect(config["tun"] == nil)
    }

    @Test func tunTurnsOnRoutesAndDNS() throws {
        var settings = RuntimeSettings()
        settings.tun = true
        let config = try RuntimeOverrideTests.config(settings)
        let tun = try #require(config["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == true && tun["stack"] as? String == "mixed" && tun["strict-route"] as? Bool == true)
        #expect(tun["dns-hijack"] as? [String] == ["any:53", "tcp://any:53"])
        #expect((tun["route-exclude-address"] as? [String])?.contains("100.64.0.0/10") == true)
        // The profile's own DNS stays, switched on.
        #expect((config["dns"] as? [String: Any])?["enable"] as? Bool == true)
        // Both build paths agree.
        let fast = try #require(try RuntimeConfig.buildKeepingSections(profile: RuntimeConfigTests.profile, settings: settings, controllerPort: 1, secret: "s"))
        let parsed = try RuntimeConfig.buildByParsing(profile: RuntimeConfigTests.profile, settings: settings, controllerPort: 1, secret: "s")
        #expect(try FastBuildTests.load(fast) == FastBuildTests.load(parsed))
    }

    @Test(.enabled(if: CoreProcessTests.binary != nil)) func theTUNConfigPassesMihomo() async throws {
        var settings = RuntimeSettings()
        settings.tun = true
        let yaml = try RuntimeConfig.build(profile: RuntimeConfigTests.profile, settings: settings, controllerPort: 1, secret: "s")
        #expect(await MihomoValidator(binary: CoreProcessTests.binary).validate(yaml).status == .passed)
    }

    @Test func pathsInTheInstallScriptAreQuoted() {
        #expect(HelperClient.quoted("/Applications/Veer.app") == "'/Applications/Veer.app'")
        #expect(HelperClient.quoted("/tmp/a'b") == "'/tmp/a'\\''b'")
    }
}

struct SubscriptionExtrasTests {
    static let gb: Int64 = 1 << 30

    @Test func trafficAlertBelowTenPercentAndExpiryWithinThreeDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageAlert.due(SubscriptionUsage(upload: 0, download: 95 * Self.gb, total: 100 * Self.gb), now: now) == [.traffic])
        #expect(UsageAlert.due(SubscriptionUsage(upload: 0, download: 80 * Self.gb, total: 100 * Self.gb), now: now).isEmpty)
        #expect(UsageAlert.due(SubscriptionUsage(expire: now.addingTimeInterval(2 * 86_400)), now: now) == [.expiry])
        #expect(UsageAlert.due(SubscriptionUsage(expire: now.addingTimeInterval(-60)), now: now) == [.expiry])
        #expect(UsageAlert.due(SubscriptionUsage(expire: now.addingTimeInterval(10 * 86_400)), now: now).isEmpty)
        #expect(UsageAlert.due(nil).isEmpty)
    }

    @Test func eachAlertGoesOutOnceUntilItClears() {
        let defaults = UserDefaults(suiteName: "veer-alerts-\(UUID().uuidString)")!
        let ledger = UsageAlertLedger(defaults: defaults)
        var profile = Profile(name: "p", isSubscription: true, nodeCount: 1, usage: SubscriptionUsage(upload: 0, download: 95 * Self.gb, total: 100 * Self.gb))
        #expect(ledger.take(for: profile) == [.traffic])
        #expect(ledger.take(for: profile).isEmpty)
        // A new month resets the traffic; running low again warns again.
        profile.usage?.download = Self.gb
        #expect(ledger.take(for: profile).isEmpty)
        profile.usage?.download = 99 * Self.gb
        #expect(ledger.take(for: profile) == [.traffic])
    }

    @Test func subscriptionsAreDueAtTheirOwnIntervalOrDaily() {
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        var profile = Profile(name: "p", isSubscription: true, updatedAt: then, nodeCount: 1)
        #expect(profile.nextUpdate == then.addingTimeInterval(24 * 3600))
        profile.updateIntervalHours = 1
        #expect(profile.nextUpdate == then.addingTimeInterval(3600))
    }

    @Test func olderIndexesAndLayersStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(Profile.self, from: Data(#"{"id":"6749D364-CFA1-4DAE-9DB1-DAE9076D3A6C","name":"p","isSubscription":true,"updatedAt":"2026-10-29T00:00:00Z","nodeCount":3}"#.utf8))
        #expect(profile.updateIntervalHours == nil && profile.updateError == nil)
        let layer = try JSONDecoder().decode(RoutingLayer.self, from: Data(#"{"edits":[],"excludedNodes":["a"]}"#.utf8))
        #expect(layer.excludedNodes == ["a"] && layer.regionMarks.isEmpty)
    }

    @Test func handMarksWinOverNames() {
        let layer = RoutingLayer(regionMarks: ["Node 7": "NL", "🇯🇵 东京 01": "US"])
        #expect(layer.region(of: "Node 7") == "NL")
        #expect(layer.region(of: "🇯🇵 东京 01") == "US")
        #expect(layer.region(of: "香港 02") == "HK")
        #expect(layer.region(of: "Node 8") == nil)
    }
}

struct RuleTemplateTests {
    static let profile = """
    mixed-port: 7890
    proxies:
      - {name: "🇯🇵 东京 01", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: x}
      - {name: "🇯🇵 东京 02", type: ss, server: 1.1.1.2, port: 443, cipher: aes-128-gcm, password: x}
      - {name: "香港 01", type: ss, server: 1.1.1.3, port: 443, cipher: aes-128-gcm, password: x}
      - {name: "US LA 01", type: ss, server: 1.1.1.4, port: 443, cipher: aes-128-gcm, password: x}
      - {name: "Node X", type: ss, server: 1.1.1.5, port: 443, cipher: aes-128-gcm, password: x}
      - {name: "剩余流量：100 GB", type: ss, server: 1.1.1.6, port: 443, cipher: aes-128-gcm, password: x}
    proxy-groups:
      - {name: Old, type: select, proxies: ["🇯🇵 东京 01"]}
    rule-providers:
      old: {type: http, behavior: domain, url: "https://example.invalid/old.yaml", interval: 86400}
    rules:
      - RULE-SET,old,Old
      - MATCH,Old
    """

    @Test func replacesGroupsAndRulesAndBuildsRegionGroups() throws {
        let text = try RuleTemplate.apply(RuleTemplate.standard, to: Self.profile, regionMarks: ["Node X": "NL"])
        let config = try #require(try Yams.load(yaml: text) as? [String: Any])
        #expect(config["rule-providers"] == nil)
        #expect((config["proxies"] as? [Any])?.count == 6)
        let groups = try #require(config["proxy-groups"] as? [[String: Any]])
        let names = groups.compactMap { $0["name"] as? String }
        #expect(!names.contains("Old"))
        let japan = try #require(groups.first { $0["name"] as? String == "🇯🇵 日本节点" })
        #expect(japan["proxies"] as? [String] == ["🇯🇵 东京 01", "🇯🇵 东京 02"])
        // The hand mark puts Node X in a Netherlands group; the info row joins nothing.
        #expect(names.contains("🇳🇱 荷兰节点"))
        #expect(!groups.contains { ($0["proxies"] as? [String])?.contains("剩余流量：100 GB") == true })
        // AI prefers the US and never offers Hong Kong.
        let ai = try #require(groups.first { $0["name"] as? String == "🤖 AI 服务" })
        #expect((ai["proxies"] as? [String])?.first == "🇺🇸 美国节点")
        #expect((ai["proxies"] as? [String])?.contains("🇭🇰 香港节点") == false)
        #expect((config["rules"] as? [String])?.last == "MATCH,🐟 漏网之鱼")
    }

    @Test func theLayerAppliesTheTemplateBeforeExclusions() throws {
        let layer = RoutingLayer(excludedNodes: ["🇯🇵 东京 02"], template: RuleTemplate.standard)
        let effective = try layer.apply(to: Self.profile)
        #expect(effective.text.contains("🚀 节点选择") && !effective.text.contains("RULE-SET,old"))
        #expect(!effective.text.contains("🇯🇵 东京 02"))
    }

    @Test(.enabled(if: CoreProcessTests.binary != nil)) func theTemplatePassesMihomo() async throws {
        let text = try RuleTemplate.apply(RuleTemplate.standard, to: Self.profile)
        let yaml = try RuntimeConfig.build(profile: text, settings: RuntimeSettings(), controllerPort: 1, secret: "s")
        let result = await MihomoValidator(binary: CoreProcessTests.binary).validate(yaml)
        #expect(result.status == .passed, "\(result.message)")
    }
}

struct BackupTests {
    static func fresh() -> (VeerPaths, UserDefaults, ProfileStore, FileKeyStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-backup-test-\(UUID().uuidString)")
        let paths = VeerPaths(root: root)
        let secrets = FileKeyStore(url: paths.secrets)
        return (paths, UserDefaults(suiteName: "veer-backup-\(UUID().uuidString)")!, ProfileStore(paths: paths, secrets: secrets), secrets)
    }

    @Test func roundTripKeepsProfilesAndSettingsButNeverKeys() throws {
        let (paths, defaults, profiles, secrets) = Self.fresh()
        let profile = Profile(name: "机场", isSubscription: true, nodeCount: 1)
        try profiles.save(profile, text: RuleTemplateTests.profile)
        try profiles.setSubscriptionURL(URL(string: "https://sub.example.invalid/token-123")!, for: profile.id)
        try secrets.save("sk-secret-key-999", for: "deepSeek")
        try RoutingStore(paths: paths).save(RoutingLayer(excludedNodes: ["香港 01"]), for: profile.id)
        defaults.set(true, forKey: "showRateInMenuBar")
        defaults.set("window junk", forKey: "NSWindow Frame main")

        let zip = paths.root.appendingPathComponent("b.zip")
        try Backup.make(paths: paths, defaults: defaults, profileStore: profiles, includeLinks: false, appVersion: "1.0", to: zip)
        let (target, targetDefaults, targetProfiles, _) = Self.fresh()
        let opened = try Backup.open(zip)
        // Every unpacked file, read as text: no key, no link, no secrets file.
        let files = FileManager.default.enumerator(at: opened.folder, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        #expect(!files.contains { $0.lastPathComponent == "secrets.json" })
        let contents = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!contents.isEmpty && !contents.contains("sk-secret-key-999") && !contents.contains("token-123"))
        #expect(opened.manifest.profiles == ["机场"] && !opened.manifest.hasSubscriptionLinks)
        try Backup.restore(from: opened.folder, paths: target, defaults: targetDefaults, profileStore: targetProfiles)
        #expect(targetProfiles.loadAll().map(\.name) == ["机场"])
        #expect(try targetProfiles.text(of: profile.id) == RuleTemplateTests.profile)
        #expect(RoutingStore(paths: target).load(profile.id).excludedNodes == ["香港 01"])
        #expect(targetDefaults.bool(forKey: "showRateInMenuBar") && targetDefaults.string(forKey: "NSWindow Frame main") == nil)
        #expect(targetProfiles.subscriptionURL(of: profile.id) == nil)
    }

    @Test func linksComeBackOnlyWhenIncluded() throws {
        let (paths, defaults, profiles, _) = Self.fresh()
        let profile = Profile(name: "机场", isSubscription: true, nodeCount: 1)
        try profiles.save(profile, text: RuleTemplateTests.profile)
        try profiles.setSubscriptionURL(URL(string: "https://sub.example.invalid/token-123")!, for: profile.id)
        let zip = paths.root.appendingPathComponent("b.zip")
        try Backup.make(paths: paths, defaults: defaults, profileStore: profiles, includeLinks: true, appVersion: "1.0", to: zip)
        let (target, targetDefaults, targetProfiles, _) = Self.fresh()
        let opened = try Backup.open(zip)
        try Backup.restore(from: opened.folder, paths: target, defaults: targetDefaults, profileStore: targetProfiles)
        #expect(targetProfiles.subscriptionURL(of: profile.id)?.absoluteString == "https://sub.example.invalid/token-123")
    }

    @Test func otherZipsAreRefused() throws {
        let (paths, _, _, _) = Self.fresh()
        try paths.prepare()
        let folder = paths.root.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let zip = paths.root.appendingPathComponent("x.zip")
        try Backup.ditto(["-c", "-k", "--keepParent", folder.path, zip.path])
        #expect(throws: (any Error).self) { try Backup.open(zip) }
    }

    @Test func diagnosticsLeaveOutServersAndPasswords() {
        let items = Diagnostics.collect(appVersion: "1.0", coreVersion: "v1", settings: RuntimeSettings(), state: "{}",
                                        effectiveConfig: RuleTemplateTests.profile, logs: ["a", "b"], coreTail: [])
        let all = items.map(\.text).joined()
        #expect(items.contains { $0.name == "config-anonymized.yaml" })
        #expect(!all.contains("1.1.1.3") && !all.contains("password: x"))
    }
}
