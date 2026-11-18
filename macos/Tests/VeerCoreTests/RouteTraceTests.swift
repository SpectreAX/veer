import Foundation
import Testing
@testable import VeerCore

/// The route tester decides each rule as Mihomo would for one destination, and says which rules it
/// cannot decide here instead of guessing.
struct RouteTraceTests {
    static func geosite() throws -> GeoSiteDatabase {
        try GeoSiteDatabase(data: GeoFixture.geosite([("netflix", [(2, "netflix.com", []), (0, "nflx", [])])]))
    }

    static func query(_ host: String, port: Int = 443, network: RouteQuery.Network = .tcp) -> RouteQuery {
        RouteQuery(host, port: port, network: network)!
    }

    static func trace(_ host: String, port: Int = 443, network: RouteQuery.Network = .tcp, rules: [String], data: RouteData = RouteData()) -> RouteTrace {
        RouteTracer.trace(query(host, port: port, network: network), rules: rules, data: data)
    }

    @Test func aDestinationIsADomainAnAddressOrAURL() {
        #expect(RouteQuery("https://WWW.Example.com/path", port: 443, network: .tcp)?.host == "www.example.com")
        #expect(RouteQuery("[2001:db8::1]", port: 53, network: .udp)?.isAddress == true)
        #expect(RouteQuery("not a host", port: 443, network: .tcp) == nil)
        #expect(RouteQuery("example.com", port: 0, network: .tcp) == nil)
        #expect(RouteQuery("example.com", port: 65536, network: .tcp) == nil)
    }

    @Test func rulesAreCheckedInOrderUpToTheFirstMatch() {
        let rules = ["DOMAIN,api.example.com,A", "DOMAIN-KEYWORD,examp,B", "DOMAIN-SUFFIX,example.com,C", "MATCH,D"]
        let trace = Self.trace("www.example.com", rules: rules)
        #expect(trace.steps.map(\.outcome) == [.notMatched, .matched])
        #expect(trace.hit?.index == 1 && trace.hit?.target == "B" && trace.certain)
        // A suffix covers the name itself and every name below it, not one that only ends the same way.
        #expect(Self.trace("example.com", rules: ["DOMAIN-SUFFIX,example.com,C"]).hit != nil)
        #expect(Self.trace("notexample.com", rules: ["DOMAIN-SUFFIX,example.com,C", "MATCH,D"]).hit?.target == "D")
        #expect(Self.trace("cdn42.example.com", rules: ["DOMAIN-REGEX,^cdn[0-9]+\\.example\\.com$,R"]).hit?.target == "R")
        // Domain rules never match an address.
        #expect(Self.trace("1.2.3.4", rules: ["DOMAIN-KEYWORD,1,K", "MATCH,D"]).hit?.target == "D")
    }

    @Test func portAndNetworkRulesUseTheDestination() {
        let quic = ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT", "MATCH,PROXY"]
        let udp = Self.trace("www.youtube.com", network: .udp, rules: quic)
        #expect(udp.hit?.target == "REJECT" && udp.hit?.conditions.map(\.outcome) == [.matched, .matched])
        #expect(Self.trace("www.youtube.com", network: .tcp, rules: quic).hit?.target == "PROXY")
        #expect(RouteEvaluator.ports("80/443/8000-8080") == [80...80, 443...443, 8000...8080])
        #expect(RouteEvaluator.ports("80-x") == nil && RouteEvaluator.ports("9-1") == nil)
        #expect(Self.trace("a.com", port: 8001, rules: ["DST-PORT,8000-8080,P", "MATCH,D"]).hit?.target == "P")
    }

    @Test func whatDependsOnTheAppStaysUndecided() {
        let rules = ["PROCESS-NAME,Telegram,TG", "SRC-IP-CIDR,192.168.1.0/24,LAN", "DOMAIN-SUFFIX,example.com,C"]
        let trace = Self.trace("www.example.com", rules: rules)
        #expect(trace.unknowns.map(\.outcome) == [.unknown(.connection("PROCESS-NAME")), .unknown(.connection("SRC-IP-CIDR"))])
        #expect(trace.hit?.target == "C" && !trace.certain)
        #expect(Self.trace("a.com", rules: ["GEOIP,CN,DIRECT,src"]).steps.first?.outcome == .unknown(.connection("GEOIP")))
        #expect(Self.trace("a.com", rules: ["SUB-RULE,(NETWORK,TCP),sub"]).steps.first?.outcome == .unknown(.unsupported("SUB-RULE")))
    }

    @Test func logicalRulesDecideAroundUndecidedConditions() {
        // AND with a condition that fails is decided whatever the undecided one says; OR with one that matches likewise.
        let and = Self.trace("a.com", network: .tcp, rules: ["AND,((PROCESS-NAME,x),(NETWORK,UDP)),X", "MATCH,D"])
        #expect(and.steps[0].outcome == .notMatched && and.certain)
        let or = Self.trace("a.com", rules: ["OR,((PROCESS-NAME,x),(DOMAIN,a.com)),X"])
        #expect(or.hit?.target == "X" && or.certain)
        // Left open by the others, the undecided one decides.
        let open = Self.trace("a.com", rules: ["AND,((PROCESS-NAME,x),(DOMAIN,a.com)),X", "MATCH,D"])
        #expect(open.steps[0].outcome == .unknown(.connection("PROCESS-NAME")) && open.hit?.target == "D" && !open.certain)
        #expect(Self.trace("a.com", rules: ["NOT,((DOMAIN,b.com)),X"]).hit?.target == "X")
        #expect(Self.trace("a.com", rules: ["NOT,((DOMAIN,a.com)),X", "MATCH,D"]).hit?.target == "D")
        #expect(Self.trace("a.com", rules: ["NOT,((PROCESS-NAME,x)),X", "MATCH,D"]).steps[0].outcome == .unknown(.connection("PROCESS-NAME")))
        // Nested logic.
        let nested = Self.trace("a.com", network: .udp, rules: ["OR,((AND,((NETWORK,UDP),(DOMAIN,a.com))),(DOMAIN,b.com)),N"])
        #expect(nested.hit?.target == "N" && nested.hit?.conditions.first?.conditions.count == 2)
    }

    @Test func ipRulesWaitForTheDomainsAddress() {
        let rules = ["IP-CIDR,10.0.0.0/8,LAN,no-resolve", "IP-CIDR,9.9.9.0/24,US", "MATCH,D"]
        let unresolved = Self.trace("dns.quad9.net", rules: rules)
        // no-resolve never resolves a domain, so that rule cannot match it.
        #expect(unresolved.steps.map(\.outcome) == [.notMatched, .unknown(.address), .matched])
        #expect(unresolved.needsAddress && !unresolved.certain)
        let resolved = Self.trace("dns.quad9.net", rules: rules, data: RouteData(address: "9.9.9.9"))
        #expect(resolved.hit?.target == "US" && resolved.certain && resolved.address == "9.9.9.9" && !resolved.needsAddress)
        // An address is its own address.
        let direct = Self.trace("10.1.2.3", rules: rules)
        #expect(direct.hit?.target == "LAN" && direct.address == nil && !direct.needsAddress)
    }

    @Test func geoipUsesTheGeoIPDataAndKnowsPrivateRangesItself() {
        let rules = ["GEOIP,LAN,DIRECT", "GEOIP,CN,DIRECT-CN", "MATCH,D"]
        #expect(Self.trace("192.168.1.10", rules: rules).hit?.target == "DIRECT")
        let noData = Self.trace("1.0.1.5", rules: rules)
        #expect(noData.steps[1].outcome == .unknown(.geoip))
        let data = RouteData(countries: { address in address.description.hasPrefix("1.0.1.") ? ["CN"] : ["US"] })
        #expect(Self.trace("1.0.1.5", rules: rules, data: data).hit?.target == "DIRECT-CN")
        #expect(Self.trace("8.8.8.8", rules: rules, data: data).hit?.target == "D")
        // A domain is not resolved for a no-resolve GEOIP rule.
        #expect(Self.trace("a.com", rules: ["GEOIP,CN,X,no-resolve", "MATCH,D"]).steps[0].outcome == .notMatched)
    }

    @Test func geositeNeedsTheGeoSiteData() throws {
        let rules = ["GEOSITE,netflix,NF", "MATCH,D"]
        #expect(Self.trace("www.netflix.com", rules: rules).steps[0].outcome == .unknown(.geosite))
        let data = RouteData(geosite: try Self.geosite())
        #expect(Self.trace("www.netflix.com", rules: rules, data: data).hit?.target == "NF")
        // Keyword entries count for GEOSITE, but MetaCubeX's rule-set files leave them out.
        #expect(Self.trace("nflxvideo.example", rules: rules, data: data).hit?.target == "NF")
        var sets = data
        sets.ruleSets["netflix"] = .geosite("netflix")
        #expect(Self.trace("nflxvideo.example", rules: ["RULE-SET,netflix,NF", "MATCH,D"], data: sets).hit?.target == "D")
        #expect(Self.trace("www.netflix.com", rules: ["RULE-SET,netflix,NF"], data: sets).hit?.target == "NF")
        #expect(Self.trace("a.com", rules: ["GEOSITE,google@cn,G"], data: data).steps[0].outcome == .unknown(.unsupported("GEOSITE")))
    }

    @Test func ruleSetsAreReadOrSaidToBeUnreadable() {
        let data = RouteData(ruleSets: [
            "domains": .domains(["+.plus.com", ".dot.com", "*.star.com", "exact.com"]),
            "cidrs": .cidrs(["9.9.9.0/24"]),
            "classical": .classical(["DOMAIN-SUFFIX,classic.com", "PROCESS-NAME,curl", "IP-CIDR,8.8.8.0/24,no-resolve"]),
        ])
        func target(_ host: String, _ set: String, _ data: RouteData = data) -> String? {
            Self.trace(host, rules: ["RULE-SET,\(set),S", "MATCH,D"], data: data).hit?.target
        }
        #expect(target("plus.com", "domains") == "S" && target("a.b.plus.com", "domains") == "S")
        #expect(target("dot.com", "domains") == "D" && target("a.dot.com", "domains") == "S")
        #expect(target("a.star.com", "domains") == "S" && target("a.b.star.com", "domains") == "D" && target("star.com", "domains") == "D")
        #expect(target("exact.com", "domains") == "S" && target("www.exact.com", "domains") == "D")
        #expect(Self.trace("a.com", rules: ["RULE-SET,cidrs,S"]).steps[0].outcome == .unknown(.ruleSet("cidrs")))
        #expect(Self.trace("a.com", rules: ["RULE-SET,cidrs,S"], data: data).steps[0].outcome == .unknown(.address))
        #expect(target("9.9.9.9", "cidrs") == "S")
        #expect(target("www.classic.com", "classical") == "S")
        // A line that cannot be decided leaves the set undecided only when no line matches.
        #expect(Self.trace("other.com", rules: ["RULE-SET,classical,S"], data: data).steps[0].outcome == .unknown(.connection("PROCESS-NAME")))
        #expect(Self.trace("a.com", rules: ["RULE-SET,missing,S"], data: data).steps[0].outcome == .unknown(.ruleSet("missing")))
    }
}
