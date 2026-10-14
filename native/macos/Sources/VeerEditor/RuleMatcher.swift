import Foundation

public struct RuleMatch: Equatable, Sendable {
    public let domain: String
    /// 1-based position, including the trailing MATCH fallback.
    public let index: Int?
    public let rule: String?
    public let target: String?
    /// Rules that need Mihomo data or DNS and were not evaluated.
    public let skipped: [String]
}

/// Offline first-match lookup for the inspector. GEOSITE and IP rules need core
/// data or a DNS answer, so they are reported as skipped instead of guessed.
public enum RuleMatcher {
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if let cut = text.firstIndex(where: { "/:?#".contains($0) }) { text = String(text[..<cut]) }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              labels.last!.count >= 2, labels.last!.allSatisfy(\.isLetter) else { return nil }
        return text
    }

    public static func match(rules: [String], domain input: String) -> RuleMatch? {
        guard let domain = normalize(input) else { return nil }
        var skipped: [String] = []
        let all = rules.last?.hasPrefix("MATCH,") == true ? rules : rules + ["MATCH,DIRECT"]
        for (offset, rule) in all.enumerated() {
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let type = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].lowercased() : ""
            if ["GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6"].contains(type) { skipped.append(rule); continue }
            let hit: Bool
            switch type {
            case "DOMAIN": hit = domain == value
            case "DOMAIN-SUFFIX": hit = domain == value || domain.hasSuffix("." + value)
            case "DOMAIN-KEYWORD": hit = !value.isEmpty && domain.contains(value)
            case "MATCH": hit = true
            default: hit = false
            }
            if hit {
                let target = type == "MATCH" ? (parts.count > 1 ? parts[1] : nil) : (parts.count > 2 ? parts[2] : nil)
                return RuleMatch(domain: domain, index: offset + 1, rule: rule, target: target, skipped: skipped)
            }
        }
        return RuleMatch(domain: domain, index: nil, rule: nil, target: nil, skipped: skipped)
    }
}
