import Foundation
import Testing
@testable import VeerCore

/// The Agent's checks decide GEOSITE, GEOIP and MetaCubeX rule sets from local geodata, through
/// the route tester's engine.
struct RuleMatcherGeoTests {
    static let geosite = try! GeoSiteDatabase(data: GeoFixture.geosite([
        ("netflix", [(2, "netflix.com", []), (0, "nflx", [])]),
        ("bilibili", [(2, "bilibili.com", [])]),
    ]))
    static let geoip = try! GeoIPDatabase(data: GeoFixture.geoip([
        ("cn", [([1, 0, 1, 0], 24)]), ("telegram", [([91, 108, 4, 0], 22)]), ("private", [([10, 0, 0, 0], 8)]),
    ]))
    static let providers = [
        ConfigDocument.Provider(key: "netflix", url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs", path: nil),
        ConfigDocument.Provider(key: "tg", url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs", path: nil),
        ConfigDocument.Provider(key: "acl", url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/Netflix.list", path: nil),
    ]
    static let rules = [
        "RULE-SET,netflix,日本出口", "GEOSITE,bilibili,DIRECT", "RULE-SET,tg,香港出口,no-resolve",
        "GEOIP,CN,DIRECT", "IP-CIDR,9.9.9.0/24,美国出口", "MATCH,自动选择",
    ]

    static func data(address: String? = nil) -> RouteData {
        RouteData(geosite: geosite, countries: DomainChecker.countries(in: geoip), ruleSets: DomainChecker.ruleSets(for: providers), address: address)
    }

    static func trace(_ host: String, rules: [String] = rules, data: RouteData = data()) -> RouteTrace {
        RouteTracer.trace(RouteQuery(host, port: 443, network: .tcp)!, rules: rules, data: data)
    }

    @Test func ruleSetsAndGeositeAreDecidedLocally() {
        #expect(DomainChecker.ruleSets(for: Self.providers) == ["netflix": .geosite("netflix"), "tg": .geoip("telegram")])
        let netflix = Self.trace("www.netflix.com")
        #expect(netflix.hit?.index == 0 && netflix.hit?.target == "日本出口" && netflix.certain && netflix.likely == nil)
        let bilibili = Self.trace("www.bilibili.com")
        #expect(bilibili.hit?.index == 1 && bilibili.certain)
        // Keyword entries count for GEOSITE rules but are not in rule-set files.
        let keyword = "nflxvideo.example"
        #expect(Self.trace(keyword, rules: ["GEOSITE,netflix,日本出口", "MATCH,DIRECT"]).hit?.index == 0)
        #expect(Self.trace(keyword, rules: ["RULE-SET,netflix,日本出口", "MATCH,DIRECT"]).hit?.index == 1)
        // A rule set Veer cannot read stays undecided.
        let unknown = Self.trace("www.netflix.com", rules: ["RULE-SET,acl,代理", "MATCH,DIRECT"])
        #expect(unknown.unknowns.map(\.index) == [0] && !unknown.certain && !unknown.needsAddress)
    }

    @Test func ipRulesUseTheResolvedAddress() {
        // A cn address: the telegram set has no-resolve (never matches a domain), GEOIP,CN decides.
        let cn = Self.trace("www.example.cn", data: Self.data(address: "1.0.1.5"))
        #expect(cn.hit?.index == 3 && cn.hit?.target == "DIRECT" && cn.certain && cn.address == "1.0.1.5")
        let elsewhere = Self.trace("www.example.org", data: Self.data(address: "9.9.9.9"))
        #expect(elsewhere.hit?.index == 4 && elsewhere.certain)
        // Not resolved yet: IP rules wait for the address.
        let pending = Self.trace("www.example.cn")
        #expect(pending.needsAddress && pending.hit?.index == 5 && !pending.certain && pending.unknowns.map(\.index) == [3, 4])
        // An IP input needs no resolving; no-resolve does not apply to it.
        let telegram = Self.trace("91.108.5.1")
        #expect(telegram.hit?.index == 2 && telegram.certain && telegram.address == nil)
        #expect(Self.trace("10.1.2.3", rules: ["GEOIP,LAN,DIRECT", "MATCH,代理"]).hit?.index == 0)
    }

    @Test func withoutGeodataNothingChanges() {
        let plain = Self.trace("www.netflix.com", data: RouteData())
        #expect(plain.likely?.index == 0 && plain.hit?.index == 5)
        let set = MetaCubeXSet(url: "https://x/geo/geosite/category-ai-!cn.mrs")
        #expect(set?.kind == "geosite" && set?.name == "category-ai-!cn")
        #expect(MetaCubeXSet(url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/Netflix.list") == nil)
        // GEOIP with no-resolve can never match a domain, so it is not listed as undecided.
        #expect(Self.trace("www.example.cn", rules: ["GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"], data: RouteData()).certain)
    }
}
