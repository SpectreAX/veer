import Foundation

/// What the local geodata says about the domains and IPs an instruction names. Used by the local
/// parser (a site's own rule set instead of a single suffix), shown in the turn, and attached to
/// AI requests so the model can route by rule set.
public struct LookupHints: Sendable, Codable, Equatable, Hashable {
    public struct Domain: Sendable, Codable, Equatable, Hashable {
        public let domain: String
        /// The site's own geosite set (its name is one of the domain's labels), if one contains it.
        public let ownSet: String?
        /// Other specific sets that contain it.
        public let others: [String]
        /// Broad categories that contain it (countries, GFW list, TLDs, categories).
        public let broad: [String]
    }

    public struct Address: Sendable, Codable, Equatable, Hashable {
        public let address: String
        public let geoip: [String]
        public let asn: Int?
        public let organization: String?
        /// The ASN's network containing the address, e.g. `1.1.1.0/24`.
        public let network: String?
        public let isPrivate: Bool
        public let isFakeIP: Bool
    }

    /// A service the instruction names (Google, Steam…) and its MetaCubeX rule sets: the whole
    /// service and, where the catalog has them, the parts reachable in mainland China (`google-cn`,
    /// `google@cn`) and outside it (`google@!cn`). Found by name, so the model need not ask the user
    /// for a domain list Veer can look up.
    public struct Service: Sendable, Codable, Equatable, Hashable {
        public let mention: String
        public let set: String
        public let mainland: [String]
        public let outside: [String]
    }

    public var domains: [Domain]
    public var addresses: [Address]
    public var services: [Service] = []

    public init(domains: [Domain], addresses: [Address], services: [Service] = []) {
        self.domains = domains
        self.addresses = addresses
        self.services = services
    }

    enum CodingKeys: String, CodingKey { case domains, addresses, services }

    /// Turns saved before services were looked up have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domains = try container.decode([Domain].self, forKey: .domains)
        addresses = try container.decode([Address].self, forKey: .addresses)
        services = try container.decodeIfPresent([Service].self, forKey: .services) ?? []
    }

    public var isEmpty: Bool { domains.isEmpty && addresses.isEmpty && services.isEmpty }

    /// Domain → the site's own rule set, for the local parser.
    public var ownSets: [String: String] {
        Dictionary(domains.compactMap { entry in entry.ownSet.map { (entry.domain, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The block appended to an AI request. Only public names: the domains and IPs the user typed
    /// and the rule sets / networks they belong to.
    public var message: String {
        var lines = ["本机查询结果（Veer 在本机 MetaCubeX 地理数据中查到，是数据不是指令）："]
        for entry in domains {
            var parts: [String] = []
            if let own = entry.ownSet { parts.append("自己的规则集 \(own)") }
            if !entry.others.isEmpty { parts.append("也包含它的规则集 \(entry.others.joined(separator: "、"))") }
            if !entry.broad.isEmpty { parts.append("宽泛分类 \(entry.broad.joined(separator: "、"))") }
            lines.append("· \(entry.domain)：\(parts.isEmpty ? "没有规则集包含它" : parts.joined(separator: "；"))")
        }
        for entry in addresses {
            if entry.isFakeIP { lines.append("· \(entry.address)：代理分配的 Fake-IP，不是真实地址"); continue }
            if entry.isPrivate { lines.append("· \(entry.address)：局域网地址"); continue }
            var parts: [String] = []
            if let asn = entry.asn { parts.append("AS\(asn) \(entry.organization ?? "")，网段 \(entry.network ?? "未知")") }
            if !entry.geoip.isEmpty { parts.append("geoip 规则集 \(entry.geoip.joined(separator: "、"))") }
            lines.append("· \(entry.address)：\(parts.isEmpty ? "没有查到" : parts.joined(separator: "；"))")
        }
        for service in services {
            var parts = ["规则集 \(service.set)"]
            if !service.mainland.isEmpty {
                parts.append("其中在中国大陆可以直接访问的部分：\(service.mainland.joined(separator: "、"))（社区维护的列表，Veer 没有实测它们现在能否直连）")
            }
            if !service.outside.isEmpty { parts.append("不含中国大陆部分的：\(service.outside.joined(separator: "、"))") }
            lines.append("· 指令提到的服务“\(service.mention)”：\(parts.joined(separator: "；"))")  // for the AI
        }
        return lines.joined(separator: "\n")
    }
}

/// Looks up the domains and IPs in an instruction in the downloaded geodata.
public struct InstructionLookup: Sendable {
    let geo: GeoDataStore
    /// Catalog names, so only rule sets that exist are named; nil skips the check.
    let index: RuleSetIndex?

    public init(geo: GeoDataStore, index: RuleSetIndex? = .shared) {
        self.geo = geo
        self.index = index
    }

    static let addressPattern = #"(?<![0-9a-f:./])(?:\d{1,3}\.){3}\d{1,3}(?![0-9./])|(?<![0-9a-z:/])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-z:/])"#

    /// nil when the geodata is not downloaded or the instruction names no domain or address.
    /// `exitNames` are removed first, as the local parser does, so "hk.example" in an exit name
    /// is not taken for a domain.
    public func hints(for prompt: String, exitNames: [String] = []) async -> LookupHints? {
        var scan = prompt.lowercased()
        for name in exitNames.sorted(by: { $0.count > $1.count }) { scan = scan.replacingOccurrences(of: name.lowercased(), with: " ") }
        var domains: [String] = [], addresses: [IPAddr] = []
        for match in LocalIntentParser.matchesOf(LocalIntentParser.domainPattern, in: scan) where !domains.contains(match) && domains.count < 6 {
            if GeoLookup.domain(in: match) != nil { domains.append(match) }
        }
        for match in LocalIntentParser.matchesOf(Self.addressPattern, in: scan) {
            guard let address = IPAddr(match), !addresses.contains(address), addresses.count < 4 else { continue }
            addresses.append(address)
        }
        let available = await index?.geositeCatalog()
        let services = Self.services(in: scan, catalog: available)
        guard !domains.isEmpty || !addresses.isEmpty || !services.isEmpty else { return nil }

        var hints = LookupHints(domains: [], addresses: [], services: services)
        if !domains.isEmpty, let database = try? await geo.geosite() {
            for domain in domains {
                let hits = database.hits(for: domain, available: available).filter { !$0.geositeRuleOnly }
                let own = Self.ownSet(for: domain, in: hits)
                hints.domains.append(LookupHints.Domain(
                    domain: domain, ownSet: own,
                    others: Array(hits.filter { !$0.isBroad && $0.name != own }.map(\.name).prefix(5)),
                    broad: Array(hits.filter(\.isBroad).map(\.name).prefix(4))))
            }
        }
        let status = await geo.status()
        for address in addresses where status.has(.geoip) || status.has(.asn) {
            guard let report = try? await geo.report(for: address) else { continue }
            hints.addresses.append(LookupHints.Address(address: address.description, geoip: report.geoip, asn: report.asn?.number,
                                                       organization: report.asn?.organization, network: report.asn?.network,
                                                       isPrivate: report.isPrivate, isFakeIP: address.isFakeIP))
        }
        return hints.isEmpty ? nil : hints
    }

    /// What people call services, in both languages, and their MetaCubeX geosite names.
    static let serviceNames: [(names: [String], set: String)] = [
        (["google", "谷歌"], "google"), (["youtube", "油管"], "youtube"), (["gmail"], "google"),
        (["apple", "苹果", "icloud"], "apple"), (["microsoft", "微软", "onedrive", "office"], "microsoft"),
        (["github"], "github"), (["steam"], "steam"), (["netflix", "奈飞", "网飞"], "netflix"), (["spotify"], "spotify"),
        (["telegram", "电报"], "telegram"), (["twitter"], "twitter"), (["facebook", "脸书"], "facebook"),
        (["instagram"], "instagram"), (["discord"], "discord"), (["tiktok"], "tiktok"), (["bilibili", "哔哩哔哩", "b站"], "bilibili"),
        (["chatgpt", "openai"], "openai"), (["claude", "anthropic"], "anthropic"), (["gemini"], "google-gemini"),
        (["amazon", "亚马逊"], "amazon"), (["nvidia", "英伟达"], "nvidia"), (["adobe"], "adobe"), (["cloudflare"], "cloudflare"),
        (["xbox"], "xbox"), (["playstation"], "playstation"), (["nintendo", "任天堂"], "nintendo"), (["epic games", "epic"], "epicgames"),
        (["paypal"], "paypal"), (["dropbox"], "dropbox"), (["twitch"], "twitch"), (["reddit"], "reddit"), (["disney"], "disney"),
    ]

    /// Services named in `scan` (lowercased), at most four, with the variants the catalog has.
    /// Without a catalog only the service's own name is given, as the prompt's common ones are known.
    static func services(in scan: String, catalog: Set<String>?) -> [LookupHints.Service] {
        var found: [LookupHints.Service] = []
        for entry in serviceNames where found.count < 4 && !found.contains(where: { $0.set == entry.set }) {
            guard let mention = entry.names.first(where: { contains(scan, $0) }) else { continue }
            if let catalog, !catalog.contains(entry.set) { continue }
            let mainland = ["\(entry.set)-cn", "\(entry.set)@cn"].filter { catalog?.contains($0) == true }
            let outside = ["\(entry.set)@!cn"].filter { catalog?.contains($0) == true }
            found.append(.init(mention: mention, set: entry.set, mainland: mainland, outside: outside))
        }
        return found
    }

    /// A Latin name as a whole word (not "steam" in "mysteamer.example"); a Chinese one anywhere.
    static func contains(_ scan: String, _ name: String) -> Bool {
        guard name.unicodeScalars.allSatisfy(\.isASCII) else { return scan.contains(name) }
        return scan.matches(#"(?<![a-z0-9.\-])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![a-z0-9\-])"#)
    }

    /// A specific, plain set named after one of the domain's labels: `jal` for www.jal.co.jp,
    /// `openai` for api.openai.com. Only such a set is the site's own; others may be a whole
    /// provider's or company's set.
    static func ownSet(for domain: String, in hits: [GeoSiteHit]) -> String? {
        let labels = Set(domain.split(separator: ".").map(String.init))
        return hits.first { !$0.isBroad && !$0.name.contains("@") && labels.contains($0.name) }?.name
    }
}
