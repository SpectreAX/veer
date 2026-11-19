import Foundation

/// Where a few domains go before and after a proposed change, decided on this Mac by the route
/// tester's engine. Each domain is checked as an HTTPS connection (TCP to 443) and nothing is
/// resolved, so a rule that needs the domain's address stays undecided.
public struct RoutePreview: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let domain: String
        /// The rule it hits now and after the change; nil when no rule matches (the core goes direct).
        public let before: RouteStep?
        public let after: RouteStep?
        /// No undecided rule comes before the hit now, and after the change. Separate, because a
        /// change often makes the new side certain (its rule comes first) while the old one was not.
        public let beforeCertain: Bool
        public let afterCertain: Bool

        public var id: String { domain }
        public var changed: Bool { before?.target != after?.target }
    }

    public let rows: [Row]

    /// At most this many domains: the card stays short.
    public static let limit = 6

    /// The domains to show, in order: the ones the user and the AI named, those the change routes by
    /// name, then a couple from each MetaCubeX GeoSite set it adds.
    public static func domains(items: [ChangeItem], named: [String], geosite: GeoSiteDatabase?) -> [String] {
        var candidates = named
        for item in items where [.route, .removeRule, .moveRule].contains(item.kind)
            && ["DOMAIN", "DOMAIN-SUFFIX"].contains(item.matchType.uppercased()) {
            candidates.append(item.match)
        }
        for item in items where item.kind == .ruleSet {
            guard let url = item.provider?.url, let set = MetaCubeXSet(url: url), set.kind == "geosite" else { continue }
            candidates += geosite?.sampleDomains(in: set.name, limit: 2) ?? []
        }
        var domains: [String] = []
        for candidate in candidates {
            guard let query = RouteQuery(candidate, port: 443, network: .tcp), !query.isAddress, !domains.contains(query.host) else { continue }
            domains.append(query.host)
            if domains.count == limit { break }
        }
        return domains
    }

    public static func make(domains: [String], before: [String], beforeData: RouteData, after: [String], afterData: RouteData) -> RoutePreview {
        let rows = domains.compactMap { domain -> Row? in
            guard let query = RouteQuery(domain, port: 443, network: .tcp) else { return nil }
            let old = RouteTracer.trace(query, rules: before, data: beforeData)
            let new = RouteTracer.trace(query, rules: after, data: afterData)
            return Row(domain: query.host, before: old.hit, after: new.hit, beforeCertain: old.unknowns.isEmpty, afterCertain: new.unknowns.isEmpty)
        }
        return RoutePreview(rows: rows)
    }
}
