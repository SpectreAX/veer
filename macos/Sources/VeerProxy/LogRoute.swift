import Foundation

/// One routing decision as the core logs it at info level:
/// `[TCP] 127.0.0.1:52344(Google Chrome) --> www.youtube.com:443 match RuleSet(youtube) using Proxy[HK 01]`.
/// Connections too short for the once-a-second poll still leave this line.
public struct LogRoute: Sendable, Equatable {
    public let network: String
    public let process: String?
    /// The domain or address, without the port.
    public let host: String
    public let port: String
    /// In the connections page's spelling: `RuleSet youtube`, `Match`.
    public let rule: String
    /// The policy first, the node last; the core logs only these two.
    public let chain: [String]

    public var isAddress: Bool { host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." } }

    public static func parse(_ line: String) -> LogRoute? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let arrow = line.range(of: " --> "), let using = line.range(of: " using ", options: .backwards) else { return nil }
        let network = line[line.index(after: line.startIndex)..<close].lowercased()
        guard network == "tcp" || network == "udp" else { return nil }

        // "127.0.0.1:52344(Google Chrome)": the process, when the core found one.
        let source = line[line.index(after: close)..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        var process: String?
        if source.hasSuffix(")"), let open = source.firstIndex(of: "(") {
            let name = source[source.index(after: open)..<source.index(before: source.endIndex)]
            process = name.isEmpty ? nil : String(name)
        }

        // "www.youtube.com:443 match RuleSet(youtube)", or "… doesn't match any rule".
        let middle = line[arrow.upperBound..<using.lowerBound]
        let target: Substring, ruleText: Substring
        // " match " also occurs inside "doesn't match", so that one goes first.
        if let none = middle.range(of: " doesn't match any rule") {
            target = middle[..<none.lowerBound]
            ruleText = "Match"
        } else if let match = middle.range(of: " match ") {
            target = middle[..<match.lowerBound]
            ruleText = middle[match.upperBound...]
        } else {
            return nil
        }
        guard let colon = target.lastIndex(of: ":") else { return nil }
        let host = String(target[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = String(target[target.index(after: colon)...])
        guard !host.isEmpty else { return nil }

        return LogRoute(network: network, process: process, host: host, port: port, rule: Self.rule(ruleText), chain: Self.chain(line[using.upperBound...]))
    }

    /// `RuleSet(youtube)` → `RuleSet youtube`; `Match()` → `Match`; logic rules stay as written.
    static func rule(_ text: Substring) -> String {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "(") else { return String(text) }
        let name = text[..<open], payload = text[text.index(after: open)..<text.index(before: text.endIndex)]
        if payload.isEmpty { return String(name) }
        if payload.contains("(") { return String(text) }
        return "\(name) \(payload)"
    }

    /// `Proxy[HK 01]` → [Proxy, HK 01]; `DIRECT` → [DIRECT].
    static func chain(_ text: Substring) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let open = trimmed.firstIndex(of: "[") else { return [trimmed] }
        let policy = String(trimmed[..<open])
        let node = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        return node.isEmpty || node == policy ? [policy] : [policy, node]
    }
}
