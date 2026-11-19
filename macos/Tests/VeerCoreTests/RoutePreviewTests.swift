import Foundation
import Testing
@testable import VeerCore

/// The Agent's card shows where a few domains go before and after a change, decided the same way as
/// Route Test.
struct RoutePreviewTests {
    /// GeoSite kinds: 0 keyword, 2 domain (suffix), 3 full.
    static func geosite() throws -> GeoSiteDatabase {
        try GeoSiteDatabase(data: GeoFixture.geosite([
            ("netflix", [(2, "netflix.com", []), (3, "fast.com", []), (0, "nflx", []), (2, "nflxvideo.net", [])]),
            ("cn", [(2, "bilibili.com", [])]),
        ]))
    }

    static func data(_ document: ConfigDocument) throws -> RouteData {
        RouteData(geosite: try geosite(), ruleSets: DomainChecker.ruleSets(for: document.providers))
    }

    static func preview(_ plan: EditPlan, named: [String]) throws -> (RoutePreview, [String]) {
        let base = try ConfigDocument.parse(SampleConfig.text)
        let result = try PlanApplier.apply(plan, to: base)
        let after = try ConfigDocument.parse(result.candidate)
        let domains = RoutePreview.domains(items: result.items, named: named, geosite: try geosite())
        let preview = RoutePreview.make(domains: domains, before: base.rules, beforeData: try data(base), after: after.rules, afterData: try data(after))
        return (preview, domains)
    }

    @Test func aRouteShowsWhereItsDomainGoesBeforeAndAfter() throws {
        let base = try ConfigDocument.parse(SampleConfig.text)
        let japan = base.target(named: "日本出口")!.id
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: japan)])
        // The user's own domains come first; one this change does not touch stays as it is.
        let (preview, domains) = try Self.preview(plan, named: ["https://www.netflix.com/browse", "chat.openai.com", "netflix.com"])
        #expect(domains == ["www.netflix.com", "chat.openai.com", "netflix.com"])
        let netflix = preview.rows[0]
        #expect(netflix.before?.target == "自动选择" && netflix.after?.target == "日本出口" && netflix.changed && netflix.beforeCertain && netflix.afterCertain)
        let openai = preview.rows[1]
        // The same rule decides it; it moved down one place, below the new rule.
        #expect(openai.before?.target == "DIRECT" && openai.after?.target == "DIRECT" && !openai.changed)
        #expect(openai.after?.rule == openai.before?.rule && openai.after?.index == (openai.before?.index ?? 0) + 1)
    }

    @Test func aRuleSetShowsAFewOfItsOwnDomains() throws {
        let base = try ConfigDocument.parse(SampleConfig.text)
        let japan = base.target(named: "日本出口")!.id
        let plan = EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: japan)])
        let (preview, domains) = try Self.preview(plan, named: [])
        // The shortest entries; keyword entries are not domains.
        #expect(domains == ["fast.com", "netflix.com"])
        #expect(preview.rows.allSatisfy { $0.before?.target == "自动选择" && $0.after?.target == "日本出口" && $0.changed && $0.beforeCertain && $0.afterCertain })
        let geosite = try Self.geosite()
        #expect(geosite.sampleDomains(in: "NETFLIX", limit: 10) == ["fast.com", "netflix.com", "nflxvideo.net"])
        #expect(geosite.sampleDomains(in: "missing", limit: 2).isEmpty)
    }

    @Test func undecidedRulesAndTheLimitAreRespected() throws {
        // Addresses, duplicates and non-domains are left out; at most `limit` domains.
        let named = ["1.2.3.4", "a.com", "A.com", "not a domain"] + (1...10).map { "site\($0).com" }
        let domains = RoutePreview.domains(items: [], named: named, geosite: nil)
        #expect(domains.count == RoutePreview.limit && domains.first == "a.com" && !domains.contains("1.2.3.4"))
        // Without geodata the GEOSITE rule before MATCH is undecided on both sides, so the row is not certain.
        let query = ["MATCH,X"], withGeosite = ["GEOSITE,cn,DIRECT", "MATCH,X"]
        let row = RoutePreview.make(domains: ["a.com"], before: query, beforeData: RouteData(), after: withGeosite, afterData: RouteData()).rows[0]
        #expect(row.beforeCertain && !row.afterCertain && !row.changed && row.after?.index == 1)
        // The other way round: a new rule in front makes the new side certain though the old one was not.
        let moved = RoutePreview.make(domains: ["a.com"], before: withGeosite, beforeData: RouteData(),
                                      after: ["DOMAIN,a.com,Y"] + withGeosite, afterData: RouteData()).rows[0]
        #expect(!moved.beforeCertain && moved.afterCertain && moved.changed)
        // No rule at all: nothing is hit, which the core treats as direct.
        #expect(RoutePreview.make(domains: ["a.com"], before: [], beforeData: RouteData(), after: [], afterData: RouteData()).rows[0].before == nil)
    }
}
