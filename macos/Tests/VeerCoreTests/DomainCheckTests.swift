import Foundation
import Testing
@testable import VeerCore

struct DomainCheckTests {
    /// `cn` covers bilibili.com and hdslb.com but not the video CDN, so it falls to MATCH.
    static func geodata() throws -> GeoDataStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GeoFixture.geosite([
            ("bilibili", [(2, "bilibili.com", []), (2, "hdslb.com", []), (2, "bilivideo.com", [])]),
            ("cn", [(2, "bilibili.com", []), (2, "hdslb.com", [])]),
        ]).write(to: directory.appendingPathComponent("geosite.dat"))
        return GeoDataStore(directory: directory)
    }

    @Test func checksDomainsAgainstTheDraft() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let checker = DomainChecker(geo: try Self.geodata(), resolver: nil, index: nil)
        let result = await checker.check(["www.bilibili.com", "upos-sz-mirrorcos.bilivideo.com"], draft: doc)
        let records = result.records
        #expect(result.geodata)
        #expect(records[0].ruleIndex == 4 && records[0].target == "DIRECT" && records[0].certain && records[0].sets.contains("bilibili"))
        #expect(records[1].ruleIndex == 7 && records[1].rule == "MATCH,自动选择" && records[1].certain && records[1].sets == ["bilibili"])

        let anonymized = AnonymizedConfig.make(document: doc, regions: Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets))
        let message = DomainChecker.message(for: records, anonymizedRules: anonymized.rules, geodata: true, lastRound: false)
        #expect(message.contains("upos-sz-mirrorcos.bilivideo.com：命中第 8 条 MATCH,"))
        #expect(message.contains("www.bilibili.com：命中第 5 条 GEOSITE,cn,DIRECT；包含它的规则集 bilibili、cn*"))
        // Exits are quoted by their anonymous labels only.
        #expect(!message.contains("自动选择"))
        #expect(DomainChecker.sanitize(["https://i0.hdslb.com/x.png", "<域名1>", "i0.hdslb.com", "not a domain"]) == ["i0.hdslb.com"])
    }

    /// The checker uses the route tester's engine and the data source it is given, so the Agent and
    /// Route Test give the same answer.
    @Test func checksUseTheRouteTestersEngineAndSource() async throws {
        let yaml = """
        proxies:
          - {name: HK, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK, DIRECT]}
        rules:
          - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
          - DST-PORT,8443,REJECT
          - RULE-SET,company,DIRECT
          - PROCESS-NAME,Telegram,DIRECT
          - RULE-SET,netflix,PROXY
          - MATCH,PROXY
        """
        let doc = try ConfigDocument.parse(yaml)
        let checker = DomainChecker(geo: nil, resolver: nil, index: nil, source: { _ in RouteData(ruleSets: ["company": .domains(["+.corp.example"])]) })
        let result = await checker.check(["git.corp.example", "www.netflix.com"], draft: doc)
        let records = result.records
        // No GeoSite data from the source or Veer: the message to the model warns about it.
        #expect(!result.geodata)
        // Checked as HTTPS: TCP to 443, so the QUIC and 8443 rules are decided and pass.
        #expect(records[0].ruleIndex == 2 && records[0].target == "DIRECT" && records[0].certain && records[0].note == nil)
        // The app-dependent rule and the unread rule set are undecided; the set named after the service likely matches first.
        #expect(records[1].ruleIndex == 5 && !records[1].certain)
        #expect(records[1].note == "第 4、5 条规则本机无法判断。第 4 条：取决于发起连接的应用或来源（PROCESS-NAME），很可能先命中第 5 条")
        let one = RouteTracer.trace(RouteQuery("a.com", port: 443, network: .tcp)!, rules: ["GEOSITE,openai,X", "MATCH,Y"], data: RouteData())
        #expect(DomainChecker.note(for: one) == "第 1 条规则本机无法判断：本机没有可用的 GeoSite 数据")
        // More than three: the first three numbers, then the count.
        let many = RouteTracer.trace(RouteQuery("a.com", port: 443, network: .tcp)!,
                                     rules: ["GEOSITE,a,X", "GEOSITE,b,X", "GEOSITE,c,X", "GEOSITE,d,X", "MATCH,Y"], data: RouteData())
        #expect(DomainChecker.note(for: many) == "第 1、2、3 条等 4 条规则本机无法判断。第 1 条：本机没有可用的 GeoSite 数据")
    }

    /// GeoSite data in the core's folder counts even when Veer has not downloaded its own.
    @Test func geodataFromTheSourceCounts() async throws {
        let geosite = try GeoSiteDatabase(data: GeoFixture.geosite([("cn", [(2, "bilibili.com", [])])]))
        let checker = DomainChecker(geo: nil, resolver: nil, index: nil, source: { _ in RouteData(geosite: geosite) })
        let result = await checker.check(["www.bilibili.com"], draft: try ConfigDocument.parse(SampleConfig.text))
        #expect(result.geodata && result.records[0].ruleIndex == 4 && result.records[0].certain)
    }

    @Test func withoutTheAppsSourceVeersGeodataAndMetaCubeXSetsAreUsed() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text + "\nrule-providers:\n  bili:\n    type: http\n    behavior: domain\n    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/bilibili.mrs\n")
        let data = await DomainChecker.data(for: doc, geo: try Self.geodata())
        #expect(data.ruleSets == ["bili": .geosite("bilibili")] && data.geosite != nil && data.countries == nil)
    }

    @Test func decodesCheckRequests() throws {
        let decoded = try EditPlan.decodeReplyWithUnderstanding(#"{"understanding":"排查","check":{"domains":["i0.hdslb.com"]}}"#)
        #expect(decoded.reply == .check(["i0.hdslb.com"]) && decoded.understanding == "排查")
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"check":{"domains":[]}}"#) }
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"check":{"domains":["a.com"]},"clarification":"x"}"#) }
    }

    final class Scripted: AITransport, @unchecked Sendable {
        let replies: [String]
        private let lock = NSLock()
        private(set) var bodies: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let index = lock.withLock { bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)); return bodies.count - 1 }
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": replies[min(index, replies.count - 1)]]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var names: [String] = []
        func add(_ event: EditorEngine.Progress) {
            switch event {
            case .checking(let domains): lock.withLock { names.append("checking:\(domains.count)") }
            case let .checked(records, sent): lock.withLock { names.append("checked:\(records.count):\(sent.contains("本机检查结果"))") }
            default: break
            }
        }
    }

    @Test func diagnosisChecksThenPlans() async throws {
        struct Pass: ConfigValidating { func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }; var versionDescription: String? { nil } }
        struct Verified: RuleSetVerifying { func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) } }
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let direct = doc.target(named: "DIRECT")!.id
        let transport = Scripted([
            #"{"understanding":"排查哔哩哔哩的 CDN","check":{"domains":["www.bilibili.com","upos-sz-mirrorcos.bilivideo.com"]}}"#,
            #"{"understanding":"视频 CDN 落到 MATCH 走了代理，用 bilibili 规则集直连","schemaVersion":1,"operations":[{"kind":"rule_set","source":"metacubex-geosite","name":"bilibili","targetId":"\#(direct)"}]}"#,
        ])
        let events = Events()
        let engine = EditorEngine(ai: AIClient(transport: transport), validator: Pass(), verifier: Verified(),
                                  checker: DomainChecker(geo: try Self.geodata(), resolver: nil, index: nil))
        let output = try await engine.run(.init(prompt: "哔哩哔哩一些 CDN 走了代理是怎么回事？", draft: doc, regions: [:], useAI: true,
                                                settings: AISettings(), apiKey: "k")) { events.add($0) }
        guard case .proposal(_, let items, _, _) = output else { Issue.record("expected proposal"); return }
        #expect(items.map(\.kind) == [.ruleSet])
        #expect(events.names == ["checking:2", "checked:2:true"])
        #expect(transport.bodies.count == 2 && transport.bodies[1].contains("本机检查结果") && transport.bodies[1].contains("命中第 8 条 MATCH"))
        // The system prompt teaches the paradigm.
        #expect(transport.bodies[0].contains("# 排查") && transport.bodies[0].contains("check"))
    }
}
