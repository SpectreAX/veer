import Foundation

/// An app or command-line tool as Veer knows it. The bundle ID is Veer's own handle for an app;
/// Mihomo never sees it, since on macOS it matches the path of the process that owns a socket.
public struct AppIdentity: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bundle, executable }

    /// What Veer can tell about where an app's traffic comes from.
    public enum Flavor: String, Codable, Sendable {
        /// Its own processes, all inside its bundle.
        case native
        /// Electron: the main process and "<Name> Helper (…)" apps inside the bundle.
        case electron
        /// Chromium: a network service helper inside the bundle's framework.
        case chromium
        /// WebKit apps such as Safari: the network requests come from the system's
        /// `com.apple.WebKit.Networking`, shared by every WebKit app, so they cannot be told apart.
        case webKit
        /// An app of the system, whose traffic often goes through shared system daemons.
        case system
        /// A command-line tool, matched by its exact path.
        case commandLine
    }

    /// A process inside the bundle that can open connections of its own.
    public struct Helper: Codable, Sendable, Hashable {
        public let name: String
        /// Real path, as the kernel reports the process.
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public let kind: Kind
    public var name: String
    public var bundleID: String?
    /// The `.app` folder as a real path (symlinks resolved, `/private` kept); nil for a tool.
    public var bundlePath: String?
    /// The main executable, as a real path.
    public var executablePath: String
    public var helpers: [Helper]
    public var flavor: Flavor

    public init(kind: Kind, name: String, bundleID: String? = nil, bundlePath: String? = nil, executablePath: String,
                helpers: [Helper] = [], flavor: Flavor = .native) {
        self.kind = kind
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.helpers = helpers
        self.flavor = flavor
    }

    /// The bundle ID for an app that has one; the path otherwise.
    public var id: String { bundleID.map { "bundle:\($0)" } ?? "path:\(bundlePath ?? executablePath)" }

    /// The folder whose processes count as this app: the bundle, or the tool itself.
    public var root: String { bundlePath ?? executablePath }

    /// Whether the kernel's path for a process belongs to this app. Case-insensitive, as Mihomo's
    /// wildcard and the default APFS volume are.
    public func owns(processPath path: String) -> Bool {
        let path = path.lowercased()
        if let bundlePath { return path.hasPrefix(bundlePath.lowercased() + "/") }
        return path == executablePath.lowercased()
    }

    /// Run from a quarantine copy (Gatekeeper's App Translocation), the path changes on every launch.
    public var isTranslocated: Bool { root.contains("/AppTranslocation/") }

    /// Its connections may come from processes it shares with other apps.
    public var sharesProcesses: Bool { flavor == .webKit || flavor == .system }
}

/// One app's route, saved in a profile's "my routing" layer.
public struct AppRule: Codable, Sendable, Identifiable, Equatable {
    public enum Target: Codable, Sendable, Hashable {
        /// No rule of its own: the profile's rules decide, as without app routing.
        case followProfile
        case direct
        case reject
        /// A group or node of the profile, by name.
        case policy(String)

        /// The policy name Mihomo reads; nil when the profile decides.
        public var policyName: String? {
            switch self {
            case .followProfile: nil
            case .direct: "DIRECT"
            case .reject: "REJECT"
            case .policy(let name): name
            }
        }

        public init(policy name: String) {
            switch name {
            case "DIRECT": self = .direct
            case "REJECT": self = .reject
            default: self = .policy(name)
            }
        }
    }

    /// Some of the app's traffic, chosen by domain, sent somewhere else than the rest of it.
    public struct DomainRoute: Codable, Sendable, Hashable, Identifiable {
        public static let matchTypes = ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD"]
        public let id: UUID
        public var matchType: String
        public var value: String
        /// Never `.followProfile`: Mihomo has no way to go on to the profile's rules for part of a match.
        public var target: Target

        public init(id: UUID = UUID(), matchType: String, value: String, target: Target) {
            self.id = id
            self.matchType = matchType
            self.value = value
            self.target = target
        }
    }

    public enum Source: String, Codable, Sendable { case manual, agent, connections }

    public let id: UUID
    public var app: AppIdentity
    /// Where the app's traffic goes, apart from its domain routes.
    public var target: Target
    /// Checked before `target`, in order.
    public var domains: [DomainRoute]
    public var enabled: Bool
    public var source: Source
    public let createdAt: Date

    public init(id: UUID = UUID(), app: AppIdentity, target: Target, domains: [DomainRoute] = [], enabled: Bool = true,
                source: Source = .manual, createdAt: Date = .now) {
        self.id = id
        self.app = app
        self.target = target
        self.domains = domains
        self.enabled = enabled
        self.source = source
        self.createdAt = createdAt
    }
}

/// What a generated rule is for.
public enum AppRuleRole: String, Codable, Sendable { case localGuard, domain, app }

/// Turns app rules into Mihomo rules, placed ahead of the profile's own.
///
/// Mihomo (v1.19.29) finds the process that owns a connection's source socket and matches its
/// executable path. So an app is matched by path, never by bundle ID:
/// - an app: `PROCESS-PATH-WILDCARD,<bundle>/*`, which also covers every helper inside the bundle
///   (Electron's "Helper (Renderer)", Chromium's network service, XPC services);
/// - a tool: `PROCESS-PATH,<path>`.
/// Mihomo splits a rule at commas and a logic rule at parentheses, and trims spaces, so a path
/// holding any of those (or the wildcard's own `*` and `?`) is written as a wildcard with `?`
/// in their place. A name that differs between NFC and NFD gets one rule for each form.
public enum AppRuleBuilder {
    /// Each address range Veer keeps off TUN (and loopback), sent direct ahead of the app rules,
    /// so an app sent to a proxy, or blocked, can still reach the local network.
    public static let localRanges = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10"]
    public static let localRanges6 = ["::1/128", "fd7a:115c:a1e0::/48", "fe80::/10"]

    /// One generated rule.
    public struct Line: Codable, Sendable, Equatable {
        /// The app rule it came from; nil for the local-network guard.
        public let ruleID: UUID?
        public let domainID: UUID?
        public let role: AppRuleRole
        /// The rule as written in the config.
        public let text: String
        public let target: String
        /// How Mihomo names this rule on a connection (`rule`, `rulePayload` of `/connections`).
        public let reportedType: String
        public let reportedPayload: String
    }

    public enum Status: Codable, Sendable, Equatable {
        /// Its rules are in the config.
        case active
        case disabled
        /// Nothing of its own: no exit and no domain routes.
        case followsProfile
        /// Exits that are no longer in the profile; the rules that used them are left out, so the
        /// profile decides for that traffic until the user picks another.
        case missingTargets([String])
        /// An earlier rule already takes all of this app's traffic.
        case shadowed(by: UUID)
    }

    public struct Report: Codable, Sendable, Equatable {
        public let lines: [Line]
        public let statuses: [UUID: Status]
        /// Profile rules that name processes, which the app rules now come before.
        public let profileProcessRules: [String]

        public static let empty = Report(lines: [], statuses: [:], profileProcessRules: [])

        public var ruleTexts: [String] { lines.map(\.text) }
        public func status(of id: UUID) -> Status? { statuses[id] }
        public func lines(of id: UUID) -> [Line] { lines.filter { $0.ruleID == id } }

        /// The generated rule a connection hit, from what `/connections` says about it.
        public func line(reportedType type: String, payload: String) -> Line? {
            lines.first { $0.reportedType == type && $0.reportedPayload == payload }
        }
    }

    /// `policies`: every group and node name of the config the rules go into.
    public static func build(_ rules: [AppRule], policies: Set<String>, profileRules: [String] = []) -> Report {
        var lines: [Line] = []
        var statuses: [UUID: Status] = [:]
        var takenWhole: [(id: UUID, app: AppIdentity)] = []
        let known = policies.union(ConfigDocument.builtinPolicies)
        for rule in rules {
            guard rule.enabled else { statuses[rule.id] = .disabled; continue }
            if let earlier = takenWhole.first(where: { covers($0.app, rule.app) }) {
                statuses[rule.id] = .shadowed(by: earlier.id)
                continue
            }
            let own = Self.lines(for: rule, known: known)
            if own.whole { takenWhole.append((rule.id, rule.app)) }
            lines += own.lines
            statuses[rule.id] = !own.missing.isEmpty ? .missingTargets(own.missing.uniqued()) : own.lines.isEmpty ? .followsProfile : .active
        }
        // The local network stays direct only when something now sends an app elsewhere.
        if lines.contains(where: { $0.target != "DIRECT" }) { lines.insert(contentsOf: localGuard, at: 0) }
        let processRules = lines.isEmpty ? [] : profileRules.filter(isProcessRule)
        return Report(lines: lines, statuses: statuses, profileProcessRules: processRules)
    }

    static var localGuard: [Line] {
        let ranges = localRanges.map { ("IP-CIDR", $0) } + localRanges6.map { ("IP-CIDR6", $0) }
        return ranges.map { type, range in
            Line(ruleID: nil, domainID: nil, role: .localGuard, text: "\(type),\(range),DIRECT,no-resolve", target: "DIRECT",
                 reportedType: "IPCIDR", reportedPayload: range)
        }
    }

    /// One rule's lines, the exits it names that are gone, and whether it takes all of the app's traffic.
    private struct RuleLines {
        var lines: [Line] = []
        var missing: [String] = []
        var whole = false
    }

    private static func lines(for rule: AppRule, known: Set<String>) -> RuleLines {
        var result = RuleLines()
        for route in rule.domains {
            guard let target = route.target.policyName, let domain = normalized(route) else { continue }
            guard known.contains(target) else { result.missing.append(target); continue }
            for matcher in matchers(for: rule.app, inLogic: true) {
                let text = "AND,((\(matcher.type),\(matcher.payload)),(\(domain.type),\(domain.value))),\(target)"
                let payload = "((\(matcher.reportedType),\(matcher.payload)) && (\(domain.reportedType),\(domain.value)))"
                result.lines.append(Line(ruleID: rule.id, domainID: route.id, role: .domain, text: text, target: target,
                                reportedType: "AND", reportedPayload: payload))
            }
        }
        guard let target = rule.target.policyName else { return result }
        guard known.contains(target) else {
            result.missing.append(target)
            return result
        }
        result.whole = true
        for matcher in matchers(for: rule.app, inLogic: false) {
            result.lines.append(Line(ruleID: rule.id, domainID: nil, role: .app, text: "\(matcher.type),\(matcher.payload),\(target)",
                            target: target, reportedType: matcher.reportedType, reportedPayload: matcher.payload))
        }
        return result
    }

    /// A rule of the profile that looks at the process, which app rules placed first can overrule.
    public static func isProcessRule(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("PROCESS-") || upper.hasPrefix("UID,") || ((upper.hasPrefix("AND,") || upper.hasPrefix("OR,") || upper.hasPrefix("NOT,"))
            && upper.contains("(PROCESS-"))
    }

    /// Whether every process of `inner` is also one of `outer`.
    static func covers(_ outer: AppIdentity, _ inner: AppIdentity) -> Bool {
        if outer.id == inner.id && outer.root == inner.root { return true }
        guard outer.bundlePath != nil else { return outer.executablePath.lowercased() == inner.root.lowercased() && inner.bundlePath == nil }
        return outer.owns(processPath: inner.root)
    }

    struct Matcher: Equatable {
        let type: String
        let payload: String
        let reportedType: String
    }

    /// How a process of `app` is recognised, in each Unicode form its name may be stored in.
    static func matchers(for app: AppIdentity, inLogic: Bool) -> [Matcher] {
        // By bytes: Swift's `==` counts the two forms as one string, and the kernel does not.
        let nfc = app.root.precomposedStringWithCanonicalMapping, nfd = app.root.decomposedStringWithCanonicalMapping
        let forms = Array(nfc.utf8) == Array(nfd.utf8) ? [nfc] : [nfc, nfd]
        return forms.map { path in
            if app.bundlePath != nil {
                return Matcher(type: "PROCESS-PATH-WILDCARD", payload: wildcard(path) + "/*", reportedType: "ProcessPathWildcard")
            }
            if isPlain(path, inLogic: inLogic) {
                return Matcher(type: "PROCESS-PATH", payload: path, reportedType: "ProcessPath")
            }
            return Matcher(type: "PROCESS-PATH-WILDCARD", payload: wildcard(path), reportedType: "ProcessPathWildcard")
        }
    }

    /// Characters Mihomo's rule syntax or wildcard reads as its own.
    static let special: Set<Character> = [",", "(", ")", "*", "?"]

    static func isPlain(_ path: String, inLogic: Bool) -> Bool {
        path == path.trimmingCharacters(in: .whitespaces) && !path.contains(where: special.contains) && !path.contains("\n")
            && !path.contains("'")
    }

    /// `?` (any one character) where the path has a character the syntax would misread; a space at
    /// either end too, since Mihomo trims them.
    static func wildcard(_ path: String) -> String {
        var chars = path.map { special.contains($0) || $0 == "\n" || $0 == "'" ? "?" : String($0) }
        if let first = chars.firstIndex(where: { $0 != " " }) { for index in chars.startIndex..<first { chars[index] = "?" } }
        if let last = chars.lastIndex(where: { $0 != " " }) { for index in chars.index(after: last)..<chars.endIndex { chars[index] = "?" } }
        return chars.joined()
    }

    struct DomainMatch {
        let type: String
        let value: String
        let reportedType: String
    }

    static func normalized(_ route: AppRule.DomainRoute) -> DomainMatch? {
        let value = route.value.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, !value.contains(where: { special.contains($0) || $0 == " " || $0 == "'" || $0 == "/" }) else { return nil }
        switch route.matchType {
        case "DOMAIN": return DomainMatch(type: "DOMAIN", value: value, reportedType: "Domain")
        case "DOMAIN-KEYWORD": return DomainMatch(type: "DOMAIN-KEYWORD", value: value, reportedType: "DomainKeyword")
        default: return DomainMatch(type: "DOMAIN-SUFFIX", value: value, reportedType: "DomainSuffix")
        }
    }
}

public extension AppRule.DomainRoute {
    /// Whether a value can be written into a rule at all.
    var isValid: Bool { AppRuleBuilder.normalized(self) != nil && target != .followProfile }
}

/// Which known app a connection came from: by the path the core reports, never by name, since
/// names repeat (every Electron app has a "… Helper") and a shared process is no one app's.
public struct AppAttribution: Sendable {
    let apps: [AppIdentity]

    public init(apps: [AppIdentity]) {
        // The deepest root first, so an app inside another app's bundle is itself.
        var seen = Set<String>()
        self.apps = apps.filter { seen.insert($0.root.lowercased()).inserted }.sorted { $0.root.count > $1.root.count }
    }

    public func app(forProcessPath path: String?) -> AppIdentity? {
        guard let path, !path.isEmpty else { return nil }
        return apps.first { $0.owns(processPath: path) }
    }
}

/// System processes that carry other apps' traffic, so a connection from one is no single app's.
public enum SharedProcesses {
    public static let names: Set<String> = [
        "com.apple.WebKit.Networking", "nsurlsessiond", "trustd", "apsd", "mDNSResponder", "cloudd", "akd", "softwareupdated",
        "com.apple.Safari.SafeBrowsing.Service", "networkserviceproxy", "nesessionmanager", "rapportd", "identityservicesd",
    ]

    public static func isShared(processName name: String?, path: String?) -> Bool {
        if let name, names.contains(name) { return true }
        guard let path else { return false }
        return path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }
}
