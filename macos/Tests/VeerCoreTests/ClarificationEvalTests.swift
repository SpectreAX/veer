import Foundation
import Testing
@testable import VeerCore

/// Offline eval of when the Agent asks instead of acting, with a scripted stand-in for the model.
/// It cannot say what a real model will do (that is `AIEvalTests`, with a key); it measures what
/// Veer gives the model and what Veer does with its answer. The stand-in behaves like the reported
/// failure: given the facts it plans, without them it asks the user for domains; it offers options
/// for real choices and asks for an exit when none is given.
struct ClarificationEvalTests {
    struct Exits {
        let direct: String, us: String, hk: String
    }

    /// The stand-in model, answering OpenAI-style requests.
    final class StandIn: AITransport, @unchecked Sendable {
        let ids: Exits
        private let lock = NSLock()
        private(set) var requests = 0, characters = 0, searches = 0

        init(ids: Exits) { self.ids = ids }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let messages = (body?["messages"] as? [[String: Any]]) ?? []
            let texts = messages.compactMap { $0["content"] as? String }
            lock.withLock { requests += 1; characters += texts.reduce(0) { $0 + $1.count } }
            let reply = answer(to: texts.dropFirst().joined(separator: "\n"), last: texts.last ?? "")
            if ProcessInfo.processInfo.environment["EVAL_DEBUG"] != nil { print("EVAL-REPLY", reply) }
            let wrapped: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": reply]]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: wrapped), response)
        }

        func lines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
            throw EditorError("not streamed")
        }

        static func plan(_ operations: [String]) -> String {
            #"{"understanding":"计划","schemaVersion":1,"operations":["# + operations.joined(separator: ",") + "]}"
        }

        func ruleSet(_ name: String, _ target: String) -> String {
            #"{"kind":"rule_set","source":"metacubex-geosite","name":"\#(name)","targetId":"\#(target)"}"#
        }

        func answer(to conversation: String, last: String) -> String {
            let lower = conversation.lowercased()
            if lower.contains("steam 下载 cdn") {
                return #"{"understanding":"两种做法","clarification":"Steam 下载 CDN 直连、其余走代理，有两种做法："# +
                    #"","options":[{"label":"A","prompt":"Steam 下载 CDN 直连，其余走美国"},{"label":"B","prompt":"新建策略组"}]}"#
            }
            if lower.contains("youtube 走代理") { return #"{"understanding":"没有出口","clarification":"请告诉我这些流量走哪个出口。"}"# }
            if lower.contains("netflix 走日本") || lower.contains("github 走美国") {
                return Self.plan([ruleSet(lower.contains("netflix") ? "netflix" : "github", ids.us)])
            }
            // The facts case: a service, its reachable-in-China part, and an exit.
            let chinese = ["google": "谷歌", "apple": "苹果", "microsoft": "微软"]
            let service = ["google", "apple", "microsoft"].first { lower.contains($0) || conversation.contains(chinese[$0]!) }!
            let target = lower.contains("香港") ? ids.hk : ids.us
            for variant in ["\(service)-cn", "\(service)@cn"] where conversation.contains("可以直接访问的部分：\(variant)") || conversation.contains("部分：\(variant)") {
                return Self.plan([ruleSet(variant, ids.direct), ruleSet(service, target)])
            }
            if last.contains("你在问用户可以查到的事实") {
                if last.contains("联网搜索") {
                    lock.withLock { searches += 1 }
                    return #"{"understanding":"先查","search":{"queries":["\#(service) domains reachable in China"]}}"#
                }
                return Self.plan([ruleSet(service, target)])
            }
            if last.contains("搜索结果") || last.contains("search") {
                let route = #"{"kind":"route","matchType":"DOMAIN-SUFFIX","match":"\#(service).cn","targetId":"\#(ids.direct)"}"#
                return Self.plan([route, ruleSet(service, target)])
            }
            return #"{"understanding":"不知道哪些域名能直连","clarification":"请告诉我哪些\#(service)域名需要直连？"}"#
        }
    }

    struct Pass: ConfigValidating {
        func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }
        var versionDescription: String? { nil }
    }

    struct Found: RuleSetVerifying {
        func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) }
    }

    struct NoSearch: RuleSearching {
        func search(_ queries: [String], config: SearchConfig) async -> [SearchRecord] {
            queries.map { SearchRecord(query: $0, source: "test") }
        }
    }

    /// `unnecessary`: a question for facts reached the user. `needed`: a question the user had to answer.
    struct Case {
        let prompt: String
        let wantsPlan: Bool
        let directFirst: String?
    }

    static let cases: [Case] = [
        .init(prompt: "Google 走美国，部分可直连域名走直连", wantsPlan: true, directFirst: "google-cn"),
        .init(prompt: "苹果国内可用的部分直连，其余走香港", wantsPlan: true, directFirst: "apple-cn"),
        .init(prompt: "Microsoft 在国内能直连的部分直连，其余走美国", wantsPlan: true, directFirst: "microsoft@cn"),
        .init(prompt: "Netflix 走日本", wantsPlan: true, directFirst: nil),
        .init(prompt: "GitHub 走美国", wantsPlan: true, directFirst: nil),
        .init(prompt: "Steam 下载 CDN 走直连，其他域名如商店、社区走代理", wantsPlan: false, directFirst: nil),
        .init(prompt: "YouTube 走代理", wantsPlan: false, directFirst: nil),
    ]

    struct Result {
        var plans = 0, accurate = 0, unnecessaryQuestions = 0, neededQuestions = 0, requests = 0, characters = 0, searches = 0
    }

    static func run(withFixes: Bool, search: Bool, lookups: Bool = true) async throws -> Result {
        let document = try ConfigDocument.parse(SampleConfig.text)
        let ids = try Exits(direct: #require(document.target(named: "DIRECT")?.id), us: #require(document.target(named: "美国出口")?.id),
                            hk: #require(document.target(named: "香港出口")?.id))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veer-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = folder.appendingPathComponent("index.json")
        let names = ["google", "google-cn", "google@cn", "google@!cn", "apple", "apple-cn", "apple@cn", "microsoft", "microsoft@cn",
                     "netflix", "github", "steam", "steam@cn", "youtube"]
        try JSONSerialization.data(withJSONObject: ["geosite": names, "geoip": ["cn"], "fetched": Date().timeIntervalSinceReferenceDate]).write(to: catalog)
        let index = RuleSetIndex(transport: URLSessionTransport(), cacheURL: catalog)
        let lookup = InstructionLookup(geo: GeoDataStore(directory: folder), index: index)
        var result = Result()
        for item in cases {
            let model = StandIn(ids: ids)
            var engine = EditorEngine(ai: AIClient(transport: model), validator: Pass(), verifier: Found(), searcher: NoSearch(),
                                      lookup: withFixes && lookups ? lookup : nil)
            engine.guardsClarifications = withFixes
            var request = EditorEngine.Request(prompt: item.prompt, draft: document, regions: [:], useAI: true,
                                               settings: AISettings(provider: .deepSeek), apiKey: "test")
            if search { request.search = SearchConfig(provider: .catalogOnly) }
            let output = try await engine.run(request) { _ in }
            result.requests += model.requests
            result.characters += model.characters
            result.searches += model.searches
            switch output {
            case let .proposal(plan, _, _, _):
                result.plans += 1
                let sets = plan.operations.compactMap { operation -> String? in
                    if case let .ruleSet(.catalog(_, name), _) = operation { return name }
                    return nil
                }
                if item.wantsPlan, item.directFirst.map({ sets.first == $0 }) ?? true { result.accurate += 1 }
            case .clarification:
                if item.wantsPlan { result.unnecessaryQuestions += 1 } else { result.neededQuestions += 1; result.accurate += 1 }
            default: break
            }
        }
        return result
    }

    @Test func factQuestionsNoLongerReachTheUserAndRealChoicesStill() async throws {
        let before = try await Self.run(withFixes: false, search: false)
        let after = try await Self.run(withFixes: true, search: false)
        let afterSearch = try await Self.run(withFixes: true, search: true)
        // Without the service lookups the guard alone sends the question back.
        let guardOnly = try await Self.run(withFixes: true, search: false, lookups: false)
        let guardSearch = try await Self.run(withFixes: true, search: true, lookups: false)
        for (label, result) in [("before", before), ("after", after), ("after+search", afterSearch), ("guard only", guardOnly), ("guard+search", guardSearch)] {
            print("CLARIFY-EVAL \(label): cases \(Self.cases.count), plans \(result.plans), accurate \(result.accurate), "
                + "unnecessary questions \(result.unnecessaryQuestions), needed questions \(result.neededQuestions), "
                + "model requests \(result.requests), searches \(result.searches), ~tokens \(result.characters / 2)")
        }
        #expect(before.unnecessaryQuestions == 3)
        #expect(after.unnecessaryQuestions == 0 && afterSearch.unnecessaryQuestions == 0)
        #expect(after.accurate == Self.cases.count, "every reachable part goes first, and real questions stay")
        #expect(after.neededQuestions == 2, "the Steam choice and the missing exit are still asked")
        #expect(after.searches == 0 && afterSearch.searches == 0, "the facts were local: no search was needed")
        #expect(guardOnly.unnecessaryQuestions == 0 && guardOnly.requests == before.requests + 3)
        #expect(guardSearch.unnecessaryQuestions == 0 && guardSearch.searches == 3)
    }
}
