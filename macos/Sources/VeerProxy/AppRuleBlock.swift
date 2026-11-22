import Foundation
import VeerCore
import Yams

/// Writes the app rules (`AppRuleBuilder`) at the top of a config's `rules`.
///
/// Order in the config the core runs, first to last: Veer's QUIC block and hot rule sets
/// (`RuntimeConfig.leadingRules`), then this block (the local-network guard, then each app's domain
/// routes and its own rule, in the user's order), then "my routing" edits and the profile's rules.
/// The hot rule sets hold no app traffic while app rules exist: `ProxyStore.hotEntries` reloads
/// instead, so a route never sits above the app rules for one run and below them after a restart.
enum AppRuleBlock {
    static func insert(_ rules: [AppRule], into text: String) throws -> (String, AppRuleBuilder.Report) {
        let document = try? ConfigDocument.parse(text)
        let policies = Set(document?.targets.filter { $0.kind != .builtin }.map(\.name) ?? [])
        let report = AppRuleBuilder.build(rules, policies: policies, profileRules: document?.rules ?? [])
        guard !report.lines.isEmpty else { return (text, report) }
        return (try prepend(report.ruleTexts, to: text), report)
    }

    /// The rules first in `rules`, as text when the config allows, else by parsing it.
    static func prepend(_ lines: [String], to text: String) throws -> String {
        let quoted = lines.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        if let blocks = TopLevelBlocks(text) {
            if let block = blocks["rules"], let rules = TopLevelBlocks.prepending(quoted, toSequence: block) {
                return blocks.blocks.map { $0.key == "rules" ? rules.hasSuffix("\n") ? rules : rules + "\n" : $0.text }.joined()
            }
            if blocks["rules"] == nil {
                let joined = blocks.blocks.map(\.text).joined()
                return (joined.hasSuffix("\n") ? joined : joined + "\n") + "rules:\n" + quoted.map { "  - \($0)\n" }.joined()
            }
        }
        guard let root = try Yams.compose(yaml: text), case .mapping(var mapping) = root else {
            throw EditorError(String(localized: "配置文件不是有效的 Mihomo 配置：顶层应该是键值对。"))
        }
        var existing: [Node] = []
        if case .sequence(let rules)? = mapping[Node("rules")] { existing = Array(rules) }
        let added = Set(lines)
        mapping[Node("rules")] = Node(lines.map { Node($0) } + existing.filter { !added.contains($0.string ?? "") })
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }
}
