import Foundation
import Testing
@testable import VeerCore

/// The controller client against a scripted core.
struct MihomoControllerTests {
    /// Records requests and answers from a table of (method path) → (status, body).
    final class FakeCore: @unchecked Sendable {
        var answers: [String: (Int, String)] = [:]
        var requests: [URLRequest] = []
        private let lock = NSLock()

        var transport: MihomoController.Transport {
            { request in
                self.lock.withLock { self.requests.append(request) }
                let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
                let (status, body) = self.lock.withLock { self.answers[key] } ?? (404, "")
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    static let draft = try! ConfigDocument.parse("""
    proxies:
      - {name: JP, type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 日本, type: select, proxies: [JP]}
      - {name: AI, type: select, proxies: [JP]}
    rules:
      - DOMAIN-SUFFIX,netflix.com,日本
      - DOMAIN-SUFFIX,openai.com,AI
      - MATCH,DIRECT
    """)

    @Test func addressesNeedHTTPSOutsideTheLocalNetwork() throws {
        #expect(try MihomoController.validate("127.0.0.1:9090").absoluteString == "http://127.0.0.1:9090")
        #expect(try MihomoController.validate("http://192.168.1.1:9090/").absoluteString == "http://192.168.1.1:9090")
        #expect(try MihomoController.validate("https://router.example.com/api").absoluteString == "https://router.example.com/api")
        #expect(throws: EditorError.self) { try MihomoController.validate("http://203.0.113.5:9090") }
        #expect(throws: EditorError.self) { try MihomoController.validate("http://user:pass@127.0.0.1:9090") }
        #expect(throws: EditorError.self) { try MihomoController.validate("http://127.0.0.1:9090/?secret=x") }
    }

    @Test func ruleUpdateSupportIsProbedWithoutSideEffects() async throws {
        let core = FakeCore()
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "s", transport: core.transport)
        core.answers["PUT /rules"] = (400, #"{"message":"Body invalid"}"#)
        #expect(try await controller.supportsRuleUpdate())
        core.answers["PUT /rules"] = (405, "")
        #expect(try await controller.supportsRuleUpdate() == false)
        // The probe body is not JSON, so a core with the endpoint changes nothing.
        #expect(core.requests.allSatisfy { String(data: $0.httpBody ?? Data(), encoding: .utf8) == "probe" })
        #expect(core.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer s" })
    }

    @Test func applySendsTheDraftAndRestoreReloadsTheCoresOwnFile() async throws {
        let core = FakeCore()
        core.answers["PUT /rules"] = (204, "")
        core.answers["PUT /configs"] = (204, "")
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: nil, transport: core.transport)
        try await controller.apply("rules: []", mode: .rules)
        try await controller.restore(mode: .config)
        let sent = try JSONSerialization.jsonObject(with: core.requests[0].httpBody!) as? [String: String]
        #expect(sent == ["payload": "rules: []"])
        #expect(core.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(core.requests[1].url?.path == "/configs" && core.requests[1].httpBody == Data("{}".utf8))
    }

    @Test func refusalsCarryTheCoresMessage() async throws {
        let core = FakeCore()
        core.answers["PUT /rules"] = (400, #"{"message":"rules[0] [Domain,a.com] error: proxy [Netflix] is not running"}"#)
        core.answers["GET /version"] = (401, #"{"message":"Unauthorized"}"#)
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "x", transport: core.transport)
        await #expect(throws: EditorError("内核拒绝了请求（HTTP 400）：rules[0] [Domain,a.com] error: proxy [Netflix] is not running")) {
            try await controller.apply("x", mode: .rules)
        }
        await #expect(throws: EditorError("控制器拒绝了访问：密钥不正确。")) { _ = try await controller.version() }
    }

    @Test func missingTargetsAndRunningRulesAreComparedByPolicy() {
        #expect(MihomoController.missingTargets(in: Self.draft, running: ["日本", "JP", "DIRECT", "REJECT"]) == ["AI"])
        let running = [MihomoController.RunningRule(type: "DomainSuffix", payload: "netflix.com", proxy: "日本"),
                       .init(type: "DomainSuffix", payload: "openai.com", proxy: "AI"),
                       .init(type: "Match", payload: "", proxy: "DIRECT")]
        #expect(MihomoController.matches(running, draft: Self.draft))
        #expect(!MihomoController.matches(Array(running.dropLast()), draft: Self.draft))
    }
}

/// The calls Veer makes to the core it runs.
struct MihomoControllerRuntimeTests {
    @Test func groupsSelectionDelayAndMode() async throws {
        let core = MihomoControllerTests.FakeCore()
        core.answers["GET /proxies"] = (200, """
        {"proxies": {"🇯🇵 日本": {"name": "🇯🇵 日本", "type": "Selector", "now": "JP 01", "all": ["JP 01", "JP 02"], "history": []},
                     "JP 01": {"name": "JP 01", "type": "Shadowsocks", "history": [{"time": "x", "delay": 120}]},
                     "DIRECT": {"name": "DIRECT", "type": "Direct"}}}
        """)
        core.answers["PUT /proxies/🇯🇵 日本"] = (204, "")
        core.answers["GET /group/🇯🇵 日本/delay"] = (200, #"{"JP 01": 120}"#)
        core.answers["GET /configs"] = (200, #"{"mode": "rule", "mixed-port": 7890}"#)
        core.answers["PATCH /configs"] = (204, "")
        core.answers["GET /connections"] = (200, #"{"uploadTotal": 10, "downloadTotal": 2048, "connections": null}"#)
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "s", transport: core.transport)

        let proxies = try await controller.proxies()
        let group = try #require(proxies["🇯🇵 日本"])
        #expect(group.isGroup && group.isSelectable && group.now == "JP 01" && group.all == ["JP 01", "JP 02"])
        #expect(proxies["JP 01"]?.lastDelay == 120 && proxies["JP 01"]?.isGroup == false)

        try await controller.select("JP 02", in: "🇯🇵 日本")
        let selection = try #require(core.requests.last)
        #expect(selection.httpMethod == "PUT")
        #expect(String(data: selection.httpBody ?? Data(), encoding: .utf8) == #"{"name":"JP 02"}"#)

        #expect(try await controller.testDelay(group: "🇯🇵 日本") == ["JP 01": 120])
        let query = try #require(core.requests.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        #expect(query.contains(URLQueryItem(name: "timeout", value: "5000")) && query.contains { $0.name == "url" })

        #expect(try await controller.mode() == "rule")
        try await controller.setMode("global")
        #expect(String(data: core.requests.last?.httpBody ?? Data(), encoding: .utf8) == #"{"mode":"global"}"#)
        let totals = try await controller.trafficTotals()
        #expect(totals.upload == 10 && totals.download == 2048)
    }
}
