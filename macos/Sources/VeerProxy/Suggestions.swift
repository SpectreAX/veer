import Foundation
import VeerCore

/// Something worth suggesting, found on this Mac without the AI. The AI is asked only when the
/// user opens a suggestion.
public struct Suggestion: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Connections to `host` keep failing.
        case failing(host: String, count: Int)
        /// `host` keeps landing on the final MATCH rule.
        case unmatched(host: String, count: Int)
        /// The node a select group uses timed out twice in a row.
        case slowNode(group: String, node: String)
        /// Several hosts keep failing through the same exit: one cause, so one suggestion.
        case outage(exit: String, hosts: [String])
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public var id: String {
        switch kind {
        case .failing(let host, _): "failing:\(host)"
        case .unmatched(let host, _): "unmatched:\(host)"
        case .slowNode(let group, let node): "slow:\(group):\(node)"
        case .outage(let exit, _): "outage:\(exit)"
        }
    }

    /// Which comes first when there are several: what breaks the most, then what is merely slow,
    /// then what only wants a rule.
    public var severity: Int {
        switch kind {
        case .outage: 3
        case .failing: 2
        case .slowNode: 1
        case .unmatched: 0
        }
    }

    /// The host "don't suggest again" applies to; nil for nodes.
    public var host: String? {
        switch kind {
        case .failing(let host, _), .unmatched(let host, _): host
        case .slowNode, .outage: nil
        }
    }
}

/// Counts failures, MATCH hits and delay timeouts and raises a suggestion once a threshold is
/// crossed: 3 failures for a host within 5 minutes, 5 MATCH hits within 10 minutes, 2 timeouts in
/// a row for the node in use. Each suggestion is raised once until it is dismissed, and not again for
/// `dismissCooldown` after that. Hosts failing through the same exit, `outageHosts` or more of them,
/// become one suggestion about that exit: the log names the exit each failed dial went through, which
/// is the evidence that they share a cause. Failures with no exit in common stay separate. What has
/// stopped happening is withdrawn (`resolved`).
public struct SuggestionDetector: Sendable {
    public static let failureWindow: TimeInterval = 300, failureCount = 3
    public static let matchWindow: TimeInterval = 600, matchCount = 5
    public static let timeoutCount = 2
    public static let outageHosts = 3
    public static let dismissCooldown: TimeInterval = 600

    private var failures: [String: [Date]] = [:]
    private var matches: [String: [Date]] = [:]
    private var timeouts: [String: Int] = [:]
    /// Suggestions raised and not yet dismissed, by id; they are not raised twice.
    private var raised: Set<String> = []
    /// The exit each host's latest failed dial went through, where the log said.
    private var failureExits: [String: String] = [:]
    /// The hosts each raised outage names, by exit.
    private var outages: [String: [String]] = [:]
    /// When each suggestion was last dismissed.
    private var dismissed: [String: Date] = [:]
    /// Slow nodes that have since answered.
    private var recovered: Set<String> = []
    /// Hosts the user asked never to hear about again.
    public var ignoredHosts: Set<String>

    public init(ignoredHosts: Set<String> = []) { self.ignoredHosts = ignoredHosts }

    public mutating func connectionFailed(host: String, exit: String? = nil, at time: Date = .now) -> Suggestion? {
        guard !Self.isIPv6Only(host) else { return nil }
        guard let count = count(host, at: time, in: &failures, window: Self.failureWindow) else { return nil }
        failureExits[host] = exit
        guard count >= Self.failureCount else { return nil }
        if let exit {
            let together = failures.filter { failureExits[$0.key] == exit && recent($0.value, at: time, window: Self.failureWindow) >= Self.failureCount }
                .keys.sorted()
            if together.count >= Self.outageHosts { return raiseOutage(exit: exit, hosts: together, at: time) }
        }
        return raise(Suggestion(kind: .failing(host: host, count: count)), at: time)
    }

    /// One suggestion for the exit, again whenever another host joins it; the hosts' own are withdrawn.
    private mutating func raiseOutage(exit: String, hosts: [String], at time: Date) -> Suggestion? {
        let suggestion = Suggestion(kind: .outage(exit: exit, hosts: hosts))
        guard !inCooldown(suggestion.id, at: time), outages[exit] != hosts else { return nil }
        outages[exit] = hosts
        raised.insert(suggestion.id)
        for host in hosts { raised.insert("failing:\(host)") }
        return suggestion
    }

    public mutating func matchedFinalRule(host: String, at time: Date = .now) -> Suggestion? {
        guard let count = count(host, at: time, in: &matches, window: Self.matchWindow), count >= Self.matchCount else { return nil }
        return raise(Suggestion(kind: .unmatched(host: host, count: count)), at: time)
    }

    /// A delay test of the node `group` uses: nil or 0 is a timeout, anything else resets.
    public mutating func tested(node: String, in group: String, delay: Int?, at time: Date = .now) -> Suggestion? {
        // REJECT and DIRECT are policies, not nodes: there is nothing to replace them with.
        guard !ConfigDocument.builtinPolicies.contains(node) else { return nil }
        let key = "\(group)\u{0}\(node)"
        guard delay == nil || delay == 0 else {
            timeouts[key] = nil
            let id = Suggestion(kind: .slowNode(group: group, node: node)).id
            if raised.remove(id) != nil { recovered.insert(id) }
            return nil
        }
        timeouts[key, default: 0] += 1
        guard timeouts[key]! >= Self.timeoutCount else { return nil }
        return raise(Suggestion(kind: .slowNode(group: group, node: node)), at: time)
    }

    /// An IPv6 address, or a name saying it answers over IPv6 only (ipv6.itdog.cn, test-ipv6.com).
    /// It fails on any node without IPv6, which is no fault of the route and no reason to change it.
    public static func isIPv6Only(_ host: String) -> Bool {
        if host.contains(":") { return true }
        return host.lowercased().split(whereSeparator: { $0 == "." || $0 == "-" }).contains { ["ipv6", "ip6", "v6"].contains($0) }
    }

    /// The user closed it; it may come back when its condition holds again, after the cooldown.
    public mutating func dismiss(_ suggestion: Suggestion, at time: Date = .now) {
        raised.remove(suggestion.id)
        dismissed[suggestion.id] = time
        switch suggestion.kind {
        case .failing(let host, _): failures[host] = nil
        case .unmatched(let host, _): matches[host] = nil
        case .slowNode(let group, let node): timeouts["\(group)\u{0}\(node)"] = nil
        case .outage(let exit, let hosts):
            outages[exit] = nil
            for host in hosts {
                failures[host] = nil
                raised.remove("failing:\(host)")
            }
        }
    }

    /// Raised suggestions whose cause has stopped: no failure or MATCH hit left in its window, every
    /// host of an outage quiet, or a slow node that answered. They are withdrawn, and may be raised again.
    public mutating func resolved(at time: Date = .now) -> Set<String> {
        var gone = recovered
        recovered = []
        for id in raised {
            if id.hasPrefix("failing:"), recent(failures[String(id.dropFirst(8))] ?? [], at: time, window: Self.failureWindow) == 0 {
                gone.insert(id)
            } else if id.hasPrefix("unmatched:"), recent(matches[String(id.dropFirst(10))] ?? [], at: time, window: Self.matchWindow) == 0 {
                gone.insert(id)
            } else if id.hasPrefix("outage:"), let hosts = outages[String(id.dropFirst(7))],
                      hosts.allSatisfy({ recent(failures[$0] ?? [], at: time, window: Self.failureWindow) == 0 }) {
                gone.insert(id)
                outages[String(id.dropFirst(7))] = nil
            }
        }
        raised.subtract(gone)
        return gone
    }

    private func recent(_ events: [Date], at time: Date, window: TimeInterval) -> Int {
        events.filter { time.timeIntervalSince($0) < window }.count
    }

    private func inCooldown(_ id: String, at time: Date) -> Bool {
        dismissed[id].map { time.timeIntervalSince($0) < Self.dismissCooldown } ?? false
    }

    /// Events in the window, this one included; nil for hosts the user ignored.
    private func count(_ host: String, at time: Date, in events: inout [String: [Date]], window: TimeInterval) -> Int? {
        guard !ignoredHosts.contains(host) else { return nil }
        var list = events[host, default: []].filter { time.timeIntervalSince($0) < window }
        list.append(time)
        events[host] = list
        return list.count
    }

    private mutating func raise(_ suggestion: Suggestion, at time: Date) -> Suggestion? {
        guard !raised.contains(suggestion.id), !inCooldown(suggestion.id, at: time) else { return nil }
        raised.insert(suggestion.id)
        return suggestion
    }

    /// The exit a failed dial went through, in the same log line: `Proxy` below.
    public static func failedExit(inLog line: String) -> String? {
        guard line.contains(" error"), let dial = line.range(of: "] dial "),
              let match = line.range(of: " (match ", range: dial.upperBound..<line.endIndex) else { return nil }
        let exit = line[dial.upperBound..<match.lowerBound].trimmingCharacters(in: .whitespaces)
        return exit.isEmpty ? nil : exit
    }

    /// The host of a failed dial in a Mihomo log line, e.g.
    /// `[TCP] dial Proxy (match RuleSet/openai) 127.0.0.1:52361(Safari) --> chatgpt.com:443 error: i/o timeout`.
    public static func failedHost(inLog line: String) -> String? {
        guard line.contains(" error"), let arrow = line.range(of: "--> ") else { return nil }
        let rest = line[arrow.upperBound...]
        guard let end = rest.firstIndex(of: " ") else { return nil }
        let target = rest[..<end]
        guard let colon = target.lastIndex(of: ":") else { return nil }
        let host = String(target[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : host
    }
}
