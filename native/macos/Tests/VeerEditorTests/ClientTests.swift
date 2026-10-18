import Foundation
import Testing
@testable import VeerEditor

@Test func invalidPortsAreRejected() {
    for port in [-1, 0, 65536] { #expect(throws: EditorFailure.self) { try EditorClient(port: port) } }
}

@Test func previewDecodesWithoutNodeConfiguration() throws {
    let json = #"{"candidate":"rules: []\n","summaries":[{"kind":"remove_rule","matchType":"DOMAIN-SUFFIX","match":"example.com","before":["DOMAIN-SUFFIX,example.com,DIRECT"],"after":null}],"warnings":[],"diff":[{"kind":"remove","text":"old"}],"changed":true,"validation":{"status":"passed","message":"placeholder only"}}"#
    let preview = try JSONDecoder().decode(Preview.self, from: Data(json.utf8))
    #expect(preview.summaries[0].target == nil)
    #expect(preview.validation.status == "passed")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Draft())) as? [String: Any]
    #expect(Set(encoded?.keys.map { $0 } ?? []) == ["groups", "rules"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) func localServerIntegration() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let port = try #require(Int(raw))
    let client = try EditorClient(port: port)
    let draft = Draft(groups: [.init(name: "日本出口", region: "JP"), .init(name: "美国出口", region: "US")])
    #expect(try await client.inspect(draft).count == 0)
    let preview = try await client.generate(draft, prompt: "Netflix 走日本，ChatGPT 走美国", mode: "local", settings: AISettings())
    #expect(preview.summaries.count == 10)
    #expect(preview.candidate.contains("DOMAIN-SUFFIX,netflix.com,日本出口"))
    #expect(!preview.candidate.contains("proxy-groups:"))
    await #expect(throws: EditorFailure.self) { try await client.inspect(Draft(rules: "proxies: []\nrules: []")) }
    await #expect(throws: EditorFailure.self) { try await client.generate(draft, prompt: "example.com 不要直连", mode: "local", settings: AISettings()) }
}

@Test func cancelledRequestStopsBeforeNetwork() async throws {
    let client = try EditorClient(port: 1)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.inspect(Draft())
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_FIXTURE_PORT"] != nil)) func redirectSizeAndProtocolErrors() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_FIXTURE_PORT"])
    let client = try EditorClient(port: #require(Int(raw)))
    for (rules, expected) in [("redirect-test", "307"), ("oversized-test", "1 MB"), ("invalid-json-test", "协议不匹配")] {
        do { _ = try await client.inspect(Draft(rules: rules)); Issue.record("预期请求被拒绝：\(rules)") }
        catch let error as EditorFailure {
            #expect(error.message.contains(expected))
            #expect(!error.message.contains("private-upstream-body"))
        }
    }
}
