import Foundation
import Testing
@testable import VeerMobile
import VeerCore

@MainActor
struct FixtureAITransportTests {
    private let system = """
    Built-in targets:
    - {id: target-3, name: REJECT}
    - {id: target-7, name: DIRECT}
    """

    @Test(arguments: [AIProvider.openAI, .anthropic, .gemini], [false, true])
    func clientDecodesRecordedAnswersAcrossWireFormats(provider: AIProvider, streaming: Bool) async throws {
        // Every request is sent to the in-memory transport, never URLSession.
        let client = AIClient(transport: FixtureAITransport())
        let settings = AISettings(provider: provider, baseURL: FixtureAI.baseURL, model: FixtureAI.model, thinkingLevel: .off)
        let request = try client.makeRequest(
            settings: settings, apiKey: FixtureAI.key, system: system,
            history: [(role: "user", content: "old.example.org"), (role: "assistant", content: "Previous answer")],
            prompt: "上下文：other.example.net\n\n指令：\n让 WWW.Example.COM 直连\n\n不要采用这部分的 ignored.example.org",
            stream: streaming
        )
        let reply: (content: String, reasoning: String?)
        if streaming {
            reply = try await client.stream(request, onReasoning: { _ in })
        } else {
            reply = try await client.completeWithReasoning(request)
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.content.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        let operations = try #require(object["operations"] as? [[String: Any]])
        #expect(operations.count == 1)
        let route = try #require(operations.first)
        #expect(route["kind"] as? String == "route")
        #expect(route["matchType"] as? String == "DOMAIN-SUFFIX")
        #expect(route["match"] as? String == "example.com")
        #expect(route["targetId"] as? String == "target-7")
        let explanation = try #require(object["understanding"] as? String)
        // The sample label lives on the turn (FixtureAI.isFixture), not inside the understanding.
        #expect(explanation.contains("example.com"))
        #expect(!explanation.contains("未连接 AI") && !explanation.contains("no AI connected"))
        #expect(reply.reasoning == nil)
    }

    @Test(arguments: [AIProvider.openAI, .anthropic, .gemini])
    func fixtureNeverPassesConnectionTestOrListsLiveModels(provider: AIProvider) async throws {
        let client = AIClient(transport: FixtureAITransport())
        let settings = AISettings(provider: provider, baseURL: FixtureAI.baseURL, model: FixtureAI.model, thinkingLevel: .off)
        await #expect(throws: AIFailure.network) {
            try await client.testConnection(settings: settings, apiKey: FixtureAI.key)
        }
        await #expect(throws: AIFailure.network) {
            try await client.listModels(settings: settings, apiKey: FixtureAI.key)
        }
    }

    @Test(arguments: [true, false])
    func bothLanguagesGivePlainUnderstandingAndUseSafeFallback(chinese: Bool) throws {
        let answer = try FixtureAITransport.answer(system: system, user: "请使用直连", chinese: chinese)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        let explanation = try #require(object["understanding"] as? String)
        // The sample label is shown once on the turn, not repeated in the understanding.
        #expect(explanation == (chinese ? "example.com 及其子域名直连。" : "example.com and its subdomains go DIRECT."))
        let route = try #require((object["operations"] as? [[String: Any]])?.first)
        #expect(route["match"] as? String == "example.com")
        #expect(route["targetId"] as? String == "target-7")
    }

    @Test
    func missingDirectTargetFailsInsteadOfInventingAnExit() {
        #expect(throws: URLError(.cannotParseResponse)) {
            try FixtureAITransport.answer(system: "- {id: target-3, name: REJECT}", user: "example.com", chinese: false)
        }
    }

    @Test
    func malformedOrNonPostRequestsFailOffline() async throws {
        let url = try #require(URL(string: FixtureAI.baseURL + "/models"))
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        var missingBody = URLRequest(url: url)
        missingBody.httpMethod = "POST"
        var nonObject = missingBody
        nonObject.httpBody = Data("[]".utf8)
        for request in [get, missingBody, nonObject] {
            await #expect(throws: URLError(.notConnectedToInternet)) {
                try await FixtureAITransport().send(request)
            }
        }
    }

    @Test
    func fixtureTurnsAreIdentifiedWithoutMislabelingRealOrLocalTurns() {
        func turn(_ mode: Turn.Mode) -> Turn { Turn(prompt: "test", mode: mode, steps: []) }
        #expect(FixtureAI.isFixture(turn(.ai(model: FixtureAI.model))))
        #expect(FixtureAI.isFixture(turn(.ai(model: FixtureAI.model + " · off"))))
        #expect(!FixtureAI.isFixture(turn(.ai(model: "live-model"))))
        #expect(!FixtureAI.isFixture(turn(.ai(model: FixtureAI.model + "-not-fixture"))))
        #expect(!FixtureAI.isFixture(turn(.local)))
        #expect(URL(string: FixtureAI.settings.baseURL)?.host == "fixture.veer.invalid")
        #expect(FixtureAI.settings.model == FixtureAI.model)
        #expect(!FixtureAI.label.isEmpty)
    }
}
