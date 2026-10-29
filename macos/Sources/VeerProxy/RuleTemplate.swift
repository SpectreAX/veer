import Foundation
import VeerCore
import Yams

/// Veer's own rule template: it replaces a profile's groups and rules and keeps its nodes. The
/// rules only name Mihomo's GEOSITE and GEOIP categories, which the core downloads itself, so no
/// third-party rule list ships with Veer. Region groups come from the profile's own nodes.
public enum RuleTemplate {
    /// The one template so far; `RoutingLayer.template` stores this id.
    public static let standard = "standard"

    public static func title(_ id: String) -> String {
        id == standard ? String(localized: "Veer 标准模板") : id
    }

    // Group names go into the config as written, so they stay Chinese in every language, like
    // the groups subscriptions ship.
    static let select = "🚀 节点选择", auto = "♻️ 自动选择", ai = "🤖 AI 服务", media = "📺 流媒体", telegram = "📲 Telegram", // written into the config
               apple = "🍎 苹果服务", microsoft = "Ⓜ️ 微软服务", domestic = "🎯 国内网站", ads = "🛑 广告拦截", final = "🐟 漏网之鱼" // written into the config

    /// At most this many region groups, the regions with the most nodes first.
    static let maxRegions = 8

    /// `profile` with the template's groups and rules. `regionMarks` are the user's hand-set
    /// regions, by node name.
    public static func apply(_ id: String, to profile: String, regionMarks: [String: String] = [:]) throws -> String {
        guard id == standard else { throw EditorError(String(localized: "找不到规则模板“\(id)”。")) }
        guard let root = try Yams.compose(yaml: profile), case .mapping(var mapping) = root else {
            throw EditorError(String(localized: "配置文件不是有效的 Mihomo 配置：顶层应该是键值对。"))
        }
        var nodes: [String] = []
        if case .sequence(let proxies)? = mapping[Node("proxies")] {
            for case .mapping(let proxy) in proxies {
                if let name = proxy[Node("name")]?.string, !NodeCleanup.isInfoNode(name) { nodes.append(name) }
            }
        }
        let hasProviders = mapping[Node("proxy-providers")] != nil
        guard !nodes.isEmpty || hasProviders else { throw EditorError(String(localized: "这个配置没有节点，无法套用模板。")) }

        let regions = Dictionary(grouping: nodes) { regionMarks[$0] ?? NodeLocator.locate($0) }
            .compactMap { code, members in code.map { (code: $0, members: members) } }
            .sorted { ($0.members.count, $1.code) > ($1.members.count, $0.code) }
            .prefix(maxRegions)
        let regionGroups = regions.map { (name: groupName(for: $0.code), members: $0.members) }
        let regionNames = regionGroups.map(\.name)
        // AI services block Hong Kong and mainland exits; prefer the US, then anywhere but Hong Kong.
        let aiRegions = regions.filter { $0.code != "HK" && $0.code != "CN" && $0.code != "MO" }
            .sorted { ($0.code == "US" ? 0 : 1) < ($1.code == "US" ? 0 : 1) }.map { groupName(for: $0.code) }

        var groups: [Node] = [
            group(select, type: "select", proxies: [auto] + regionNames + ["DIRECT"], includeAll: true),
            group(auto, type: "url-test", proxies: [], includeAll: true, test: true),
        ]
        groups += regionGroups.map { group($0.name, type: "url-test", proxies: $0.members, test: true) }
        groups += [
            group(ai, type: "select", proxies: aiRegions + [select]),
            group(media, type: "select", proxies: [select] + regionNames),
            group(telegram, type: "select", proxies: [select] + regionNames),
            group(apple, type: "select", proxies: ["DIRECT", select]),
            group(microsoft, type: "select", proxies: ["DIRECT", select]),
            group(domestic, type: "select", proxies: ["DIRECT", select]),
            group(ads, type: "select", proxies: ["REJECT", "DIRECT"]),
            group(final, type: "select", proxies: [select, "DIRECT"]),
        ]
        mapping[Node("proxy-groups")] = Node(groups)
        mapping[Node("rule-providers")] = nil
        mapping[Node("rules")] = Node(rules.map { Node($0) })
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }

    /// "🇯🇵 日本节点": the flag and the Chinese name, whatever the interface language.
    static func groupName(for code: String) -> String {
        let place = NodeLocator.place(code)
        let name = Locale(identifier: "zh-Hans").localizedString(forRegionCode: code) ?? code
        return "\(place?.flag ?? "") \(name)节点".trimmingCharacters(in: .whitespaces) // written into the config
    }

    private static func group(_ name: String, type: String, proxies: [String], includeAll: Bool = false, test: Bool = false) -> Node {
        var pairs: [(Node, Node)] = [(Node("name"), Node(name)), (Node("type"), Node(type))]
        if !proxies.isEmpty { pairs.append((Node("proxies"), Node(proxies.map { Node($0) }))) }
        if includeAll { pairs.append((Node("include-all"), Node("true", Tag(.bool)))) }
        if test {
            pairs += [(Node("url"), Node("https://www.gstatic.com/generate_204")), (Node("interval"), Node("300", Tag(.int))),
                      (Node("tolerance"), Node("50", Tag(.int)))]
        }
        return Node(pairs)
    }

    static let rules: [String] = [
        "GEOSITE,private,DIRECT",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
        "GEOSITE,category-ads-all,\(ads)",
        "GEOSITE,openai,\(ai)",
        "GEOSITE,anthropic,\(ai)",
        "GEOSITE,google-gemini,\(ai)",
        "GEOSITE,category-ai-!cn,\(ai)",
        "GEOSITE,telegram,\(telegram)",
        "GEOSITE,youtube,\(media)",
        "GEOSITE,netflix,\(media)",
        "GEOSITE,disney,\(media)",
        "GEOSITE,spotify,\(media)",
        "GEOSITE,tiktok,\(media)",
        "GEOSITE,apple,\(apple)",
        "GEOSITE,microsoft,\(microsoft)",
        "GEOSITE,github,\(select)",
        "GEOSITE,google,\(select)",
        "GEOSITE,geolocation-!cn,\(select)",
        "GEOSITE,cn,\(domestic)",
        "GEOIP,CN,\(domestic)",
        "MATCH,\(final)",
    ]
}
