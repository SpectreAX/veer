import Foundation

/// A destination as the rules see it: a domain or an address, a port and TCP or UDP.
public struct RouteQuery: Sendable, Equatable {
    public enum Network: String, Sendable, CaseIterable, Identifiable {
        case tcp = "TCP", udp = "UDP"
        public var id: String { rawValue }
    }

    /// A lowercase domain, or an IP address.
    public let host: String
    public let port: Int
    public let network: Network

    /// `input` may be a domain, an address or a URL; nil when it is none of these or the port is out of range.
    public init?(_ input: String, port: Int, network: Network) {
        guard let host = RuleMatcher.normalize(input), (1...65535).contains(port) else { return nil }
        self.host = host
        self.port = port
        self.network = network
    }

    public var isAddress: Bool { IPAddress(host) != nil }
}

/// Why a rule cannot be decided on this Mac.
public enum RouteUnknown: Sendable, Hashable {
    /// An IP rule, and the domain has not been resolved.
    case address
    /// A GEOSITE rule, and no GeoSite data is on this Mac.
    case geosite
    /// A GEOIP rule, and no GeoIP data is on this Mac.
    case geoip
    /// A rule set whose contents Veer cannot read (not downloaded, or in the binary MRS format).
    case ruleSet(String)
    /// Depends on the app or the connection: the process, the source address, the inbound.
    case connection(String)
    /// A rule type Veer does not evaluate.
    case unsupported(String)

    /// Why, in a few words, for the route tester and the Agent's checks.
    public var explanation: String {
        switch self {
        case .address: String(localized: "需要域名的 IP 地址")
        case .geosite: String(localized: "本机没有可用的 GeoSite 数据")
        case .geoip: String(localized: "本机没有可用的 GeoIP 数据")
        case .ruleSet(let name): String(localized: "规则集“\(name)”的内容无法读取")
        case .connection(let type): String(localized: "取决于发起连接的应用或来源（\(type)）")
        case .unsupported(let type): String(localized: "Veer 不判断 \(type) 规则")
        }
    }
}

public enum RouteOutcome: Sendable, Hashable {
    case matched
    case notMatched
    case unknown(RouteUnknown)

    public var unknown: RouteUnknown? { if case .unknown(let reason) = self { reason } else { nil } }
}

/// One rule, or one condition of a logical rule, and what it gave.
public struct RouteStep: Sendable, Hashable, Identifiable {
    /// The rule's 0-based position in the config, or the condition's position in its rule.
    public let index: Int
    /// As written, without the target for a condition.
    public let rule: String
    public let target: String?
    public let outcome: RouteOutcome
    /// The conditions of AND, OR and NOT, in order.
    public let conditions: [RouteStep]

    public var id: Int { index }

    /// Whether this step, or any condition in it, waits on the domain's address.
    var waitsForAddress: Bool { outcome == .unknown(.address) || conditions.contains(where: \.waitsForAddress) }
}

/// A rule set's contents: read from the file the core downloaded, or a MetaCubeX set looked up in the geodata.
public enum RuleSetContents: Sendable, Equatable {
    /// `domain` behavior entries: `example.com`, `+.example.com`, `.example.com`, `*.example.com`.
    case domains([String])
    /// `ipcidr` behavior entries.
    case cidrs([String])
    /// `classical` behavior: one condition per line, such as `DOMAIN-SUFFIX,example.com`.
    case classical([String])
    case geosite(String)
    case geoip(String)
}

/// What the rules are checked against, all of it on this Mac.
public struct RouteData: Sendable {
    public var geosite: GeoSiteDatabase?
    /// The GEOIP codes of an address, uppercase; nil when no GeoIP data is on this Mac.
    public var countries: (@Sendable (IPAddr) -> Set<String>)?
    /// Rule-provider name → its contents; a name missing here cannot be read.
    public var ruleSets: [String: RuleSetContents]
    /// The domain's address, once resolved; IP rules use it unless they say `no-resolve`.
    public var address: String?

    public init(geosite: GeoSiteDatabase? = nil, countries: (@Sendable (IPAddr) -> Set<String>)? = nil,
                ruleSets: [String: RuleSetContents] = [:], address: String? = nil) {
        self.geosite = geosite
        self.countries = countries
        self.ruleSets = ruleSets
        self.address = address
    }
}

/// Every rule checked in order, up to the first one that certainly matches.
public struct RouteTrace: Sendable, Equatable {
    public let query: RouteQuery
    public let steps: [RouteStep]
    /// The address IP rules were checked against, for a domain.
    public let address: String?

    /// The first rule that certainly matches; nil when none does.
    public var hit: RouteStep? { steps.last.flatMap { $0.outcome == .matched ? $0 : nil } }
    /// Rules before the hit that could not be decided here: any of them may match first.
    public var unknowns: [RouteStep] { steps.filter { $0.outcome.unknown != nil } }
    public var certain: Bool { hit != nil && unknowns.isEmpty }
    /// A rule waited on the domain's address: resolving it and tracing again can decide more.
    public var needsAddress: Bool { !query.isAddress && address == nil && steps.contains(where: \.waitsForAddress) }
    /// The first undecided rule that probably matches: a rule set or GEOSITE named after the
    /// service in the domain (`RULE-SET,netflix` for www.netflix.com).
    public var likely: RouteStep? {
        guard !query.isAddress else { return nil }
        return unknowns.first { step in
            guard let parts = RuleParts.parse(step.rule), ["RULE-SET", "GEOSITE"].contains(parts.type), let name = parts.payload else { return false }
            return RuleMatcher.namesService(name, in: query.host)
        }
    }

    public static func == (lhs: RouteTrace, rhs: RouteTrace) -> Bool {
        lhs.query == rhs.query && lhs.steps == rhs.steps && lhs.address == rhs.address
    }
}

/// Decides each rule the way Mihomo would for one destination, without making a connection. A rule
/// that needs something Veer does not have says so instead of guessing.
public enum RouteTracer {
    public static func trace(_ query: RouteQuery, rules: [String], data: RouteData) -> RouteTrace {
        let evaluator = RouteEvaluator(query: query, data: data)
        var steps: [RouteStep] = []
        for (index, line) in rules.enumerated() {
            guard let parts = RuleParts.parse(line) else { continue }
            let (outcome, conditions) = parts.type == "MATCH"
                ? (.matched, [])
                : evaluator.evaluate(type: parts.type, payload: parts.payload ?? "", flags: parts.flags, depth: 0)
            steps.append(RouteStep(index: index, rule: line, target: parts.target, outcome: outcome, conditions: conditions))
            if outcome == .matched { break }
        }
        return RouteTrace(query: query, steps: steps, address: query.isAddress ? nil : data.address)
    }

    /// Types that depend on who opens the connection or how it arrives, which a destination alone cannot say.
    static let connectionTypes: Set<String> = [
        "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX", "PROCESS-NAME-WILDCARD", "PROCESS-PATH-WILDCARD",
        "UID", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "SRC-IP-ASN", "SRC-GEOIP", "SRC-PORT", "IN-PORT", "IN-TYPE", "IN-USER", "IN-NAME", "DSCP",
    ]
}

/// Decides one rule or condition for one destination.
struct RouteEvaluator {
    let query: RouteQuery
    let data: RouteData
    let ip: IPAddress?

    init(query: RouteQuery, data: RouteData) {
        self.query = query
        self.data = data
        ip = IPAddress(query.host)
    }

    enum Address { case known(String), never, unknown }

    /// The address an IP rule checks: the destination itself, or the domain's resolved one unless
    /// the rule says not to resolve.
    func address(noResolve: Bool) -> Address {
        if ip != nil { return .known(query.host) }
        if noResolve { return .never }
        return data.address.map(Address.known) ?? .unknown
    }

    func evaluate(type: String, payload: String, flags: [String], depth: Int) -> (RouteOutcome, [RouteStep]) {
        let type = type.uppercased()
        let noResolve = flags.contains { $0.lowercased() == "no-resolve" }
        if flags.contains(where: { $0.lowercased() == "src" }) || RouteTracer.connectionTypes.contains(type) {
            return (.unknown(.connection(type)), [])
        }
        switch type {
        case "AND", "OR", "NOT": return logical(type, payload: payload, depth: depth)
        case "RULE-SET": return (ruleSet(payload, noResolve: noResolve, depth: depth), [])
        default: return (destination(type, payload: payload, noResolve: noResolve), [])
        }
    }

    /// Rules on the destination alone: its name, address, port and network.
    func destination(_ type: String, payload: String, noResolve: Bool) -> RouteOutcome {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX": return domain(type, payload.lowercased())
        case "GEOSITE": return ip == nil ? geosite(payload.lowercased()) : .notMatched
        case "IP-CIDR", "IP-CIDR6": return cidr(payload, noResolve: noResolve)
        case "GEOIP": return geoip(payload, noResolve: noResolve)
        case "DST-PORT":
            guard let ranges = Self.ports(payload) else { return .unknown(.unsupported(type)) }
            return ranges.contains { $0.contains(query.port) } ? .matched : .notMatched
        case "NETWORK": return payload.uppercased() == query.network.rawValue ? .matched : .notMatched
        default: return .unknown(.unsupported(type))
        }
    }

    func domain(_ type: String, _ value: String) -> RouteOutcome {
        guard ip == nil else { return .notMatched }
        let host = query.host
        switch type {
        case "DOMAIN": return host == value ? .matched : .notMatched
        case "DOMAIN-SUFFIX": return host == value || host.hasSuffix("." + value) ? .matched : .notMatched
        case "DOMAIN-KEYWORD": return host.contains(value) ? .matched : .notMatched
        default:
            guard let regex = try? NSRegularExpression(pattern: value) else { return .unknown(.unsupported(type)) }
            return regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil ? .matched : .notMatched
        }
    }

    /// `inRuleSet`: MetaCubeX's rule-set files keep only the full and suffix entries of a list, not its
    /// keyword and regex ones, which only a GEOSITE rule matches through.
    func geosite(_ name: String, inRuleSet: Bool = false) -> RouteOutcome {
        // An attribute (`google@cn`) selects part of a list, which the lookup below does not.
        guard !name.contains("@") else { return .unknown(.unsupported("GEOSITE")) }
        guard let database = data.geosite else { return .unknown(.geosite) }
        let hits = database.hits(for: query.host, available: [name]).filter { !inRuleSet || !$0.geositeRuleOnly }
        return hits.isEmpty ? .notMatched : .matched
    }

    func cidr(_ value: String, noResolve: Bool) -> RouteOutcome {
        switch address(noResolve: noResolve) {
        case .never: return .notMatched
        case .unknown: return .unknown(.address)
        case .known(let text):
            guard let network = IPAddress.network(value) else { return .unknown(.unsupported("IP-CIDR")) }
            return IPAddress(text).map(network.contains) == true ? .matched : .notMatched
        }
    }

    func geoip(_ value: String, noResolve: Bool) -> RouteOutcome {
        let code = value.uppercased()
        switch address(noResolve: noResolve) {
        case .never: return .notMatched
        case .unknown: return .unknown(.address)
        case .known(let text):
            guard let parsed = IPAddr(text) else { return .notMatched }
            if code == "LAN" || code == "PRIVATE" { return parsed.isPrivate ? .matched : .notMatched }
            guard let countries = data.countries else { return .unknown(.geoip) }
            return countries(parsed).contains(code) ? .matched : .notMatched
        }
    }

    func ruleSet(_ name: String, noResolve: Bool, depth: Int) -> RouteOutcome {
        guard let contents = data.ruleSets[name] else { return .unknown(.ruleSet(name)) }
        switch contents {
        case .domains(let entries):
            guard ip == nil else { return .notMatched }
            return entries.contains { Self.domainEntry($0, matches: query.host) } ? .matched : .notMatched
        case .cidrs(let entries): return cidrs(entries, noResolve: noResolve)
        case .classical(let lines): return classical(lines, depth: depth)
        case .geosite(let set): return ip == nil ? geosite(set, inRuleSet: true) : .notMatched
        case .geoip(let set): return geoip(set, noResolve: noResolve)
        }
    }

    func cidrs(_ entries: [String], noResolve: Bool) -> RouteOutcome {
        switch address(noResolve: noResolve) {
        case .never: return .notMatched
        case .unknown: return .unknown(.address)
        case .known(let text):
            guard let found = IPAddress(text) else { return .notMatched }
            return entries.contains { IPAddress.network($0)?.contains(found) == true } ? .matched : .notMatched
        }
    }

    /// A classical set matches when any line does; an undecided line decides it only when no line matches.
    func classical(_ lines: [String], depth: Int) -> RouteOutcome {
        guard depth < 8 else { return .unknown(.unsupported("RULE-SET")) }
        var unknown: RouteOutcome?
        for line in lines {
            let parts = RuleParts.split(line)
            guard let type = parts.first, parts.count > 1 else { continue }
            let (outcome, _) = evaluate(type: type, payload: parts[1], flags: Array(parts.dropFirst(2)), depth: depth + 1)
            if outcome == .matched { return .matched }
            if unknown == nil, outcome.unknown != nil { unknown = outcome }
        }
        return unknown ?? .notMatched
    }

    /// AND, OR and NOT over conditions that may be undecided: an undecided condition decides the
    /// rule only when the others leave it open.
    func logical(_ type: String, payload: String, depth: Int) -> (RouteOutcome, [RouteStep]) {
        guard depth < 8, let items = Self.conditions(payload), !items.isEmpty else { return (.unknown(.unsupported(type)), []) }
        let steps = items.enumerated().map { offset, item in
            let parts = RuleParts.split(item)
            let (outcome, nested) = parts.count > 1
                ? evaluate(type: parts[0], payload: parts[1], flags: Array(parts.dropFirst(2)), depth: depth + 1)
                : (.unknown(.unsupported(parts.first ?? type)), [])
            return RouteStep(index: offset, rule: item, target: nil, outcome: outcome, conditions: nested)
        }
        let outcomes = steps.map(\.outcome)
        let firstUnknown = outcomes.first { $0.unknown != nil }
        switch type {
        case "AND":
            if outcomes.contains(.notMatched) { return (.notMatched, steps) }
            return (firstUnknown ?? .matched, steps)
        case "OR":
            if outcomes.contains(.matched) { return (.matched, steps) }
            return (firstUnknown ?? .notMatched, steps)
        default:
            guard outcomes.count == 1 else { return (.unknown(.unsupported(type)), steps) }
            switch outcomes[0] {
            case .matched: return (.notMatched, steps)
            case .notMatched: return (.matched, steps)
            case .unknown: return (outcomes[0], steps)
            }
        }
    }

    /// `((DOMAIN,a.com),(NETWORK,UDP))` → `["DOMAIN,a.com", "NETWORK,UDP"]`.
    static func conditions(_ payload: String) -> [String]? {
        var text = payload.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("("), text.hasSuffix(")") else { return nil }
        text = String(text.dropFirst().dropLast())
        return RuleParts.split(text).map { item in
            var item = item
            if item.hasPrefix("("), item.hasSuffix(")") { item = String(item.dropFirst().dropLast()) }
            return item.trimmingCharacters(in: .whitespaces)
        }
    }

    /// `443`, `80/443` or `1000-2000`; nil when any part is not a port.
    static func ports(_ payload: String) -> [ClosedRange<Int>]? {
        var ranges: [ClosedRange<Int>] = []
        for part in payload.split(separator: "/") {
            let pieces = part.split(separator: "-")
            let bounds = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == pieces.count, (1...2).contains(bounds.count), let low = bounds.first, let high = bounds.last, low <= high else { return nil }
            ranges.append(low...high)
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// A `domain` behavior entry: `+.a.com` is a.com and below it, `.a.com` only below it,
    /// `*.a.com` one label below it, anything else exactly that name.
    static func domainEntry(_ entry: String, matches host: String) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if entry.hasPrefix("+.") {
            let base = String(entry.dropFirst(2))
            return host == base || host.hasSuffix("." + base)
        }
        if entry.hasPrefix("*.") {
            let base = String(entry.dropFirst(2))
            guard host.hasSuffix("." + base) else { return false }
            return !host.dropLast(base.count + 1).contains(".")
        }
        if entry.hasPrefix(".") { return host.hasSuffix(entry) }
        return host == entry
    }
}
