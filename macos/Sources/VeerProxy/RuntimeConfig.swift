import Foundation
import VeerCore
import Yams

/// What the user sets for the running core, on top of any profile.
public struct RuntimeSettings: Sendable, Equatable, Codable {
    /// How the core answers DNS: fake IPs (fast, needed for TUN) or real ones.
    public enum DNSMode: String, Sendable, Codable, CaseIterable {
        case fakeIP = "fake-ip", redirHost = "redir-host"
    }

    /// One port for HTTP and SOCKS; the system proxy points here.
    public var mixedPort = 7890
    public var allowLAN = false
    public var logLevel = "info"
    public var ipv6 = false
    /// Match rules by the process that opened a connection, and show it on the connections page.
    /// Mihomo's "strict" only looks processes up when a rule names one, which leaves the
    /// connections page without them, so Veer asks for "always".
    public var processMatching = true
    /// Reject QUIC (UDP 443) so browsers fall back to TCP, which proxies better.
    public var disableQUIC = false
    public var dnsMode = DNSMode.fakeIP
    public var dnsServers = RuntimeSettings.defaultDNSServers
    /// Keep a profile's own `dns` section; Veer's DNS settings apply only to profiles without one.
    public var preferProfileDNS = true
    /// Route all traffic through a TUN device (the core then runs as root, through the helper).
    public var tun = false

    public static let defaultDNSServers = ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"]

    public init(mixedPort: Int = 7890, allowLAN: Bool = false, logLevel: String = "info") {
        self.mixedPort = mixedPort
        self.allowLAN = allowLAN
        self.logLevel = logLevel
    }

    /// Settings saved by an older Veer lack the newer fields; they take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RuntimeSettings()
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? defaults.mixedPort
        allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? defaults.allowLAN
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? defaults.logLevel
        ipv6 = try container.decodeIfPresent(Bool.self, forKey: .ipv6) ?? defaults.ipv6
        processMatching = try container.decodeIfPresent(Bool.self, forKey: .processMatching) ?? defaults.processMatching
        disableQUIC = try container.decodeIfPresent(Bool.self, forKey: .disableQUIC) ?? defaults.disableQUIC
        dnsMode = try container.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? defaults.dnsMode
        dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? defaults.dnsServers
        preferProfileDNS = try container.decodeIfPresent(Bool.self, forKey: .preferProfileDNS) ?? defaults.preferProfileDNS
        tun = try container.decodeIfPresent(Bool.self, forKey: .tun) ?? defaults.tun
    }
}

/// The config Mihomo runs: the profile as it is, with Veer's ports and controller written over it.
public enum RuntimeConfig {
    /// Keys a profile may set that would open another way in, clash with Veer's port, or start
    /// TUN before Veer manages it.
    static let removed = [
        "port", "socks-port", "redir-port", "tproxy-port", "external-controller-tls", "external-controller-unix",
        "external-controller-pipe", "external-controller-cors", "external-ui", "external-ui-url", "external-ui-name", "tun",
    ]

    static let geodataMirrors: [(key: String, url: String)] = [
        ("geoip", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"),
        ("geosite", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"),
        ("mmdb", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"),
        ("asn", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"),
    ]

    /// `hot`: Veer's in-place rule sets (`HotRuleSets`), for the core Veer runs; never in exports.
    public static func build(profile: String, settings: RuntimeSettings, controllerPort: Int, secret: String,
                             hot: HotRuleSets? = nil) throws -> String {
        if let fast = try buildKeepingSections(profile: profile, settings: settings, controllerPort: controllerPort, secret: secret, hot: hot) {
            return fast
        }
        return try buildByParsing(profile: profile, settings: settings, controllerPort: controllerPort, secret: secret, hot: hot)
    }

    /// Rules Veer puts first, in order: the QUIC block, then the hot rule sets (single-quoted,
    /// since a group name may hold characters YAML reads as syntax).
    static func leadingRules(_ settings: RuntimeSettings, hot: HotRuleSets?, quoted: Bool) -> [String] {
        var rules = settings.disableQUIC ? [quicRule] : []
        rules += (hot?.rules ?? []).map { quoted ? "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" : $0 }
        return rules
    }

    /// Top-level keys Veer writes itself; the profile's own are dropped.
    static let overridden = ["mixed-port", "allow-lan", "log-level", "external-controller", "secret", "profile", "ipv6", "find-process-mode", "dns"]

    /// Veer's keys, in the order they are written.
    static func overrides(_ settings: RuntimeSettings, controllerPort: Int, secret: String, profileDNS: Node?, hasGeodataSource: Bool) -> [(Node, Node)] {
        var pairs: [(Node, Node)] = [
            (Node("mixed-port"), Node(String(settings.mixedPort), Tag(.int))),
            (Node("allow-lan"), Node(settings.allowLAN ? "true" : "false", Tag(.bool))),
            (Node("log-level"), Node(settings.logLevel)),
            (Node("external-controller"), Node("127.0.0.1:\(controllerPort)")),
            (Node("secret"), Node(secret, Tag(.str), .doubleQuoted)),
            // Keep the user's node choices and fake-IP mappings across restarts.
            (Node("profile"), Node([(Node("store-selected"), Node("true", Tag(.bool))), (Node("store-fake-ip"), Node("true", Tag(.bool)))])),
            (Node("ipv6"), Node(settings.ipv6 ? "true" : "false", Tag(.bool))),
            (Node("find-process-mode"), Node(settings.processMatching ? "always" : "off", Tag(.str), .doubleQuoted)),
        ]
        // A DNS listener is only for TUN or redirection, and port 53 needs root: without it the
        // core would fail to start as the user. The rest of `dns` (resolvers, fake-IP) applies.
        if case .mapping(var dns)? = profileDNS, settings.preferProfileDNS {
            dns[Node("listen")] = nil
            // TUN hijacks DNS to the core, which then has to answer it.
            if settings.tun { dns[Node("enable")] = Node("true", Tag(.bool)) }
            pairs.append((Node("dns"), .mapping(dns)))
        } else {
            pairs.append((Node("dns"), dnsSection(settings)))
        }
        if settings.tun { pairs.append((Node("tun"), tunSection)) }
        // Geodata is downloaded on the first start, before the proxy works; GitHub is often
        // unreachable then, so use the jsDelivr mirror unless the profile names its own.
        if !hasGeodataSource {
            pairs.append((Node("geox-url"), Node(geodataMirrors.map { (Node($0.key), Node($0.url)) })))
        }
        return pairs
    }

    /// Keeps the profile's large sections (proxies, groups, rules, providers) as written and only
    /// writes the keys Veer owns: parsing and writing a whole subscription of ten thousand lines
    /// took seconds on every reload. Nil when the text is not plain enough to cut safely
    /// (anchors and aliases, top-level flow style, documents), so the full parse handles it.
    static func buildKeepingSections(profile: String, settings: RuntimeSettings, controllerPort: Int, secret: String,
                                     hot: HotRuleSets? = nil) throws -> String? {
        guard let blocks = TopLevelBlocks(profile) else { return nil }
        var dns: Node?
        if settings.preferProfileDNS, let text = blocks["dns"] {
            guard case .mapping(let mapping)? = try? Yams.compose(yaml: text), let section = mapping[Node("dns")] else { return nil }
            dns = section
        }
        var rules = blocks["rules"]
        let leading = leadingRules(settings, hot: hot, quoted: true)
        if !leading.isEmpty {
            if var text = rules {
                for rule in leading.reversed() {
                    guard let next = TopLevelBlocks.prepending(rule, toSequence: text) else { return nil }
                    text = next
                }
                rules = text
            } else {
                rules = "rules:\n" + leading.map { "  - \($0)\n" }.joined()
            }
        }
        var providers = blocks["rule-providers"]
        if let hot {
            if let text = providers {
                guard let merged = TopLevelBlocks.appending(hot.providerEntries, toMapping: text) else { return nil }
                providers = merged
            } else {
                providers = "rule-providers:\n" + hot.providerEntries.map { "  \($0)\n" }.joined()
            }
        }
        let dropped = Set(removed + overridden)
        var output = ""
        for block in blocks.blocks {
            if let key = block.key, dropped.contains(key) { continue }
            output += block.key == "rules" ? (rules ?? block.text) : block.key == "rule-providers" ? (providers ?? block.text) : block.text
            if !output.hasSuffix("\n") { output += "\n" }
        }
        if blocks["rule-providers"] == nil, let providers { output += providers }
        if blocks["rules"] == nil, let rules { output += rules }
        let ours = overrides(settings, controllerPort: controllerPort, secret: secret, profileDNS: dns, hasGeodataSource: blocks["geox-url"] != nil)
        output += "# Veer\n" + ConfigImporter.readableUnicode(try Yams.serialize(node: Node(ours), allowUnicode: true))
        return output
    }

    /// The whole profile parsed and written again: for text the faster path cannot cut safely.
    static func buildByParsing(profile: String, settings: RuntimeSettings, controllerPort: Int, secret: String,
                               hot: HotRuleSets? = nil) throws -> String {
        guard let root = try Yams.compose(yaml: profile), case .mapping(var mapping) = root else {
            throw EditorError(String(localized: "配置文件不是有效的 Mihomo 配置：顶层应该是键值对。"))
        }
        for key in removed { mapping[Node(key)] = nil }
        let dns = mapping[Node("dns")]
        for (key, value) in overrides(settings, controllerPort: controllerPort, secret: secret, profileDNS: dns,
                                      hasGeodataSource: mapping[Node("geox-url")] != nil) {
            mapping[key] = value
        }
        if let hot {
            if case .mapping(var providers)? = mapping[Node("rule-providers")] {
                for (key, value) in hot.providerNodes { providers[key] = value }
                mapping[Node("rule-providers")] = .mapping(providers)
            } else {
                mapping[Node("rule-providers")] = Node(hot.providerNodes)
            }
        }
        // First, so no rule sends QUIC to a proxy before it, and Veer's hot rules win over the profile's.
        let leading = leadingRules(settings, hot: hot, quoted: false)
        if !leading.isEmpty {
            var rules: [Node] = []
            if case .sequence(let existing)? = mapping[Node("rules")] { rules = Array(existing) }
            mapping[Node("rules")] = Node(leading.map { Node($0) } + rules.filter { !leading.contains($0.string ?? "") })
        }
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }

    /// Addresses that stay off the TUN device: the local network, link-local, Tailscale's
    /// 100.64/10 and its IPv6 range, and IPv6 link-local.
    static let tunExcluded = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
                              "fd7a:115c:a1e0::/48", "fe80::/10"]

    /// The TUN device: mixed stack, Mihomo setting the routes and finding the outgoing interface,
    /// strict routing so nothing slips past, and every DNS query answered by the core.
    static var tunSection: Node {
        Node([
            (Node("enable"), Node("true", Tag(.bool))),
            (Node("stack"), Node("mixed")),
            (Node("auto-route"), Node("true", Tag(.bool))),
            (Node("auto-detect-interface"), Node("true", Tag(.bool))),
            (Node("strict-route"), Node("true", Tag(.bool))),
            (Node("dns-hijack"), Node([Node("any:53"), Node("tcp://any:53")])),
            (Node("route-exclude-address"), Node(tunExcluded.map { Node($0) })),
        ])
    }

    /// UDP to port 443 is QUIC (HTTP/3); rejecting it makes browsers retry over TCP.
    static let quicRule = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"

    /// Hosts that must get real addresses: the local network, Apple push, time servers and game
    /// consoles break with fake ones.
    static let fakeIPFilter = ["*.lan", "*.local", "+.push.apple.com", "time.*.com", "ntp.*.com", "+.ntp.org",
                               "+.xboxlive.com", "+.playstation.net", "+.nintendo.net"]

    /// Veer's DNS for profiles without their own: encrypted upstreams, also used to resolve the
    /// proxy servers themselves.
    static func dnsSection(_ settings: RuntimeSettings) -> Node {
        let servers = Node(settings.dnsServers.map { Node($0) })
        var pairs: [(Node, Node)] = [
            (Node("enable"), Node("true", Tag(.bool))),
            (Node("ipv6"), Node(settings.ipv6 ? "true" : "false", Tag(.bool))),
            (Node("enhanced-mode"), Node(settings.dnsMode.rawValue)),
        ]
        if settings.dnsMode == .fakeIP {
            pairs.append((Node("fake-ip-range"), Node("198.18.0.1/16")))
            pairs.append((Node("fake-ip-filter"), Node(fakeIPFilter.map { Node($0) })))
        }
        pairs += [(Node("nameserver"), servers), (Node("proxy-server-nameserver"), servers)]
        return Node(pairs)
    }

    /// The config to export with Veer's overrides written in: what `build` makes, without the
    /// controller and secret, which only mean something to one run of the core.
    public static func export(profile: String, settings: RuntimeSettings) throws -> String {
        let built = try build(profile: profile, settings: settings, controllerPort: 0, secret: "")
        guard let root = try Yams.compose(yaml: built), case .mapping(var mapping) = root else { return built }
        mapping[Node("external-controller")] = nil
        mapping[Node("secret")] = nil
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }

    /// A random controller secret for one run of the core.
    public static func makeSecret() -> String {
        (0..<32).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }
}

/// A YAML document cut at its top-level keys, each block kept as written.
struct TopLevelBlocks {
    struct Block {
        /// Nil for comments before the first key.
        let key: String?
        var text: String
    }

    private(set) var blocks: [Block] = []

    /// Anchors (`&base`) and aliases (`*base`, `<<: *base`) tie blocks together: dropping one
    /// could break another. `*.lan` is a wildcard, not an alias.
    static let anchorOrAlias = try! NSRegularExpression(pattern: #"(^|[:\-\[,{]\s*)[&*][A-Za-z0-9_\-]+[ \t]*($|[,\]}\s])"#, options: .anchorsMatchLines)

    init?(_ text: String) {
        guard Self.anchorOrAlias.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { return nil }
        var keys = Set<String>()
        var current = Block(key: nil, text: "")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // "- item" at column 0 belongs to the key above it ("rules:" then "- MATCH,DIRECT").
            if let first = line.first, first != " ", first != "\t", first != "#", !(first == "-" && current.key != nil && !line.hasPrefix("---")) {
                guard !"-[{%&*!|>".contains(first), !line.hasPrefix("---"), !line.hasPrefix("..."),
                      let key = Self.key(of: line), keys.insert(key).inserted else { return nil }
                blocks.append(current)
                current = Block(key: key, text: "")
            }
            current.text += line + "\n"
        }
        blocks.append(current)
        if blocks.first?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { blocks.removeFirst() }
        guard !keys.isEmpty else { return nil }
    }

    subscript(key: String) -> String? { blocks.first { $0.key == key }?.text }

    /// `key:` at the start of a line; quoted keys are unquoted.
    static func key(of line: Substring) -> String? {
        if let quote = line.first, quote == "'" || quote == "\"" {
            let rest = line.dropFirst()
            guard let close = rest.firstIndex(of: quote), rest[rest.index(after: close)...].hasPrefix(":") else { return nil }
            return String(rest[..<close])
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// `entries` (`name: value` lines) added at the end of a block-style mapping, at its own
    /// indent. Nil for anything else, such as `rule-providers: {…}`.
    static func appending(_ entries: [String], toMapping block: String) -> String? {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, let colon = header.firstIndex(of: ":") else { return nil }
        let after = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return nil }
        let children = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let indent = children.first.map { String($0.prefix { $0 == " " }) } ?? "  "
        guard !indent.isEmpty else { return nil }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines += entries.map { indent + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `rule` as the first item of a block-style sequence (`rules:` then `- …` lines), without a
    /// second copy of it. Nil for anything else, such as `rules: [a, b]`.
    static func prepending(_ rule: String, toSequence block: String) -> String? {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, let colon = header.firstIndex(of: ":"),
              header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces).isEmpty
                || header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
        let items = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let indent = items.first.map { String($0.prefix { $0 == " " }) } ?? "  "
        guard items.allSatisfy({ $0.hasPrefix(indent + "- ") || $0.hasPrefix(indent + "  ") }) else { return nil }
        lines.removeAll { line in
            let item = line.trimmingCharacters(in: .whitespaces)
            return item == "- \(rule)" || item == "- '\(rule)'" || item == "- \"\(rule)\""
        }
        lines.insert(indent + "- " + rule, at: 1)
        return lines.joined(separator: "\n")
    }
}
