import Foundation

/// Whether a policy group serves anything (node selection, a region, the final MATCH) or one
/// service only (媒体解锁, AI网站, a game's own group). Read from the real name on this Mac; the
/// AI sees only the verdict, never the name.
public enum GroupPurpose {
    /// A group for one service: its name says neither a region nor a general role.
    public static func isDedicated(_ name: String) -> Bool {
        if NodeLocator.locate(name) != nil { return false }
        let range = NSRange(name.startIndex..., in: name)
        return general.firstMatch(in: name, range: range) == nil
    }

    /// Words of general roles. English ones only as whole words: "GlobalMedia" is a media group.
    private static let general = try! NSRegularExpression(
        pattern: #"节点|线路|选择|手动|自动|代理|故障转移|负载均衡|漏网|兜底|其他|其它|全球|国外|海外|默认|直连|机场|全部|(?<![A-Za-z])(?:proxy|proxies|auto|select|selector|url-?test|fallback|load-?balance|final|match|global|others?|default|direct|all)(?![A-Za-z])"#,
        options: .caseInsensitive)

    /// Dedicated groups the items send traffic to without the instruction naming them.
    public static func unnamedDedicated(in items: [ChangeItem], instruction: String) -> [String] {
        let said = squeezed(instruction)
        var found: [String] = []
        for item in items where item.kind == .route || item.kind == .ruleSet {
            guard let target = item.targetName, isDedicated(target), !found.contains(target) else { continue }
            let name = squeezed(target)
            if name.isEmpty || !said.contains(name) { found.append(target) }
        }
        return found
    }

    /// Letters and digits only, lower-cased: "🎬 媒体解锁" and "媒体解锁" are the same name.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
    }
}
