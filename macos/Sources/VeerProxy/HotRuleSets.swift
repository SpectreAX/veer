import Foundation
import VeerCore
import Yams

/// Rule sets Veer refreshes in place, so a new "X 走 Y" takes effect without reloading the
/// whole config: one empty file rule set per policy (every group, DIRECT and REJECT), each with
/// a rule near the top of the rules that sends its matches to that policy. A new route is
/// written into its policy's file and only that rule set is reloaded (`PUT /providers/rules`),
/// which costs well under a millisecond and drops no connection. The files start empty on every
/// full build: by then "my routing" has the route in the config itself.
public struct HotRuleSets: Sendable, Equatable {
    public struct RuleSet: Sendable, Equatable {
        public let name: String
        public let target: String
        /// Relative to the core's home, where Mihomo allows file rule sets.
        public var path: String { "./\(HotRuleSets.folder)/\(name).yaml" }
    }

    public static let folder = "veer-hot"
    public let sets: [RuleSet]

    public init(targets: [String]) {
        var seen = Set<String>()
        sets = targets.filter { seen.insert($0).inserted }.enumerated().map { RuleSet(name: "veer-hot-\($0.offset + 1)", target: $0.element) }
    }

    /// Every policy group of `profile`, then DIRECT and REJECT.
    public static func forProfile(_ profile: String) -> HotRuleSets? {
        guard let document = try? ConfigDocument.parse(profile) else { return nil }
        return HotRuleSets(targets: document.targets.filter { $0.kind == .group }.map(\.name) + ["DIRECT", "REJECT"])
    }

    public func set(for target: String) -> RuleSet? { sets.first { $0.target == target } }

    /// Writes every rule set empty into `home`, before the core reads the config.
    public func resetFiles(in home: URL) throws {
        let folder = home.appendingPathComponent(Self.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for set in sets { try Data(Self.file([]).utf8).write(to: folder.appendingPathComponent("\(set.name).yaml"), options: .atomic) }
    }

    public func write(_ lines: [String], to set: RuleSet, in home: URL) throws {
        let url = home.appendingPathComponent(Self.folder, isDirectory: true).appendingPathComponent("\(set.name).yaml")
        try Data(Self.file(lines).utf8).write(to: url, options: .atomic)
    }

    /// The rules that send each set's matches to its policy, in the config's spelling.
    var rules: [String] { sets.map { "RULE-SET,\($0.name),\($0.target)" } }

    /// `name: {type: file, …}` for each set, as lines of a block-style mapping.
    var providerEntries: [String] {
        sets.map { "\($0.name): {type: file, behavior: classical, path: \($0.path), format: yaml}" }
    }

    var providerNodes: [(Node, Node)] {
        sets.map { set in
            (Node(set.name), Node([(Node("type"), Node("file")), (Node("behavior"), Node("classical")),
                                   (Node("path"), Node(set.path)), (Node("format"), Node("yaml"))]))
        }
    }

    /// The rule-set line for a route, or nil when the route cannot live in a rule set.
    public static func line(matchType: String, match: String) -> String? {
        let type = matchType.uppercased()
        guard ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6"].contains(type),
              !match.isEmpty, !match.contains(","), !match.contains("\n") else { return nil }
        return "\(type),\(match)"
    }

    /// Whether a connection to `host` is one `line` would now route.
    public static func matches(_ line: String, host: String) -> Bool {
        let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let host = host.lowercased(), value = parts[1].lowercased()
        switch parts[0] {
        case "DOMAIN": return host == value
        case "DOMAIN-SUFFIX": return host == value || host.hasSuffix("." + value)
        case "DOMAIN-KEYWORD": return host.contains(value)
        default: return false
        }
    }

    static func file(_ lines: [String]) -> String {
        lines.isEmpty ? "payload: []\n" : "payload:\n" + lines.map { "  - '\($0.replacingOccurrences(of: "'", with: "''"))'\n" }.joined()
    }
}
