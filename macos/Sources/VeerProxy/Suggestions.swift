import Foundation

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
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public var id: String {
        switch kind {
        case .failing(let host, _): "failing:\(host)"
        case .unmatched(let host, _): "unmatched:\(host)"
        case .slowNode(let group, let node): "slow:\(group):\(node)"
        }
    }

    /// The host "don't suggest again" applies to; nil for nodes.
    public var host: String? {
        switch kind {
        case .failing(let host, _), .unmatched(let host, _): host
        case .slowNode: nil
        }
    }
}

/// Counts failures, MATCH hits and delay timeouts and raises a suggestion once a threshold is
/// crossed: 3 failures for a host within 5 minutes, 5 MATCH hits within 10 minutes, 2 timeouts in
/// a row for the node in use. Each suggestion is raised once until it is dismissed.
public struct SuggestionDetector: Sendable {
    public static let failureWindow: TimeInterval = 300, failureCount = 3
    public static let matchWindow: TimeInterval = 600, matchCount = 5
    public static let timeoutCount = 2

    private var failures: [String: [Date]] = [:]
    private var matches: [String: [Date]] = [:]
    private var timeouts: [String: Int] = [:]
    /// Suggestions raised and not yet dismissed, by id; they are not raised twice.
    private var raised: Set<String> = []
    /// Hosts the user asked never to hear about again.
    public var ignoredHosts: Set<String>

    public init(ignoredHosts: Set<String> = []) { self.ignoredHosts = ignoredHosts }

    public mutating func connectionFailed(host: String, at time: Date = .now) -> Suggestion? {
        guard let count = count(host, at: time, in: &failures, window: Self.failureWindow), count >= Self.failureCount else { return nil }
        return raise(Suggestion(kind: .failing(host: host, count: count)))
    }

    public mutating func matchedFinalRule(host: String, at time: Date = .now) -> Suggestion? {
        guard let count = count(host, at: time, in: &matches, window: Self.matchWindow), count >= Self.matchCount else { return nil }
        return raise(Suggestion(kind: .unmatched(host: host, count: count)))
    }

    /// A delay test of the node `group` uses: nil or 0 is a timeout, anything else resets.
    public mutating func tested(node: String, in group: String, delay: Int?) -> Suggestion? {
        let key = "\(group)\u{0}\(node)"
        guard delay == nil || delay == 0 else {
            timeouts[key] = nil
            return nil
        }
        timeouts[key, default: 0] += 1
        guard timeouts[key]! >= Self.timeoutCount else { return nil }
        return raise(Suggestion(kind: .slowNode(group: group, node: node)))
    }

    /// The user closed it; it may come back when its condition holds again.
    public mutating func dismiss(_ suggestion: Suggestion) {
        raised.remove(suggestion.id)
        switch suggestion.kind {
        case .failing(let host, _): failures[host] = nil
        case .unmatched(let host, _): matches[host] = nil
        case .slowNode(let group, let node): timeouts["\(group)\u{0}\(node)"] = nil
        }
    }

    /// Events in the window, this one included; nil for hosts the user ignored.
    private func count(_ host: String, at time: Date, in events: inout [String: [Date]], window: TimeInterval) -> Int? {
        guard !ignoredHosts.contains(host) else { return nil }
        var list = events[host, default: []].filter { time.timeIntervalSince($0) < window }
        list.append(time)
        events[host] = list
        return list.count
    }

    private mutating func raise(_ suggestion: Suggestion) -> Suggestion? {
        guard !raised.contains(suggestion.id) else { return nil }
        raised.insert(suggestion.id)
        return suggestion
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
