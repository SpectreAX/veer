import Foundation
import Testing
@testable import VeerCore

/// Runtime actions: what the model may ask Veer to do to the running core.
struct RuntimeActionTests {
    static let config = """
    proxies:
      - {name: 🇺🇸 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 东京 01, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: AI, type: select, proxies: [🇺🇸 洛杉矶 01, 🇯🇵 东京 01]}
      - {name: 日本, type: select, proxies: [🇯🇵 东京 01]}
    rules:
      - MATCH,AI
    """

    @Test func aRuntimeReplyDecodes() throws {
        let reply = try EditPlan.decodeReplyWithUnderstanding("""
        {"understanding":"ChatGPT 走的 AI 策略组换到最快的美国节点","runtime":{"actions":[
          {"kind":"select_fastest","groupId":"target-0","regions":["us"]},
          {"kind":"mode","mode":"Rule"},
          {"kind":"close_connections","host":"Chatgpt.com"}]}}
        """)
        #expect(reply.understanding?.contains("ChatGPT") == true)
        #expect(reply.reply == .runtime([.selectFastest(groupId: "target-0", regions: [.us]),
                                          .mode("rule"), .closeConnections(host: "chatgpt.com")]))
    }

    @Test func malformedRuntimeRepliesAreRefused() {
        let bad = [
            #"{"runtime":{"actions":[]}}"#,
            #"{"runtime":{"actions":[{"kind":"mode","mode":"tun"}]}}"#,
            #"{"runtime":{"actions":[{"kind":"select","groupId":"target-0"}]}}"#,
            #"{"runtime":{"actions":[{"kind":"reboot"}]}}"#,
            #"{"runtime":{"actions":[{"kind":"close_connections","host":"a b"}]}}"#,
            #"{"runtime":{"actions":[{"kind":"test","groupId":"target-0"}]},"clarification":"?"}"#,
        ]
        for text in bad { #expect(throws: EditorError.self, "\(text)") { try EditPlan.decodeReply(text) } }
    }

    @Test func idsResolveToNamesAndMembersAreChecked() throws {
        let draft = try ConfigDocument.parse(Self.config)
        let ai = try #require(draft.target(named: "AI")), japan = try #require(draft.target(named: "日本"))
        let us = try #require(draft.target(named: "🇺🇸 洛杉矶 01")), node = try #require(draft.target(named: "🇯🇵 东京 01"))
        #expect(try RuntimeAction.select(groupId: ai.id, targetId: us.id).resolved(in: draft) == .select(group: "AI", node: "🇺🇸 洛杉矶 01"))
        #expect(try RuntimeAction.test(groupId: japan.id).resolved(in: draft) == .test(group: "日本"))
        // Not a member of 日本, and a node is not a group.
        #expect(throws: EditorError.self) { try RuntimeAction.select(groupId: japan.id, targetId: us.id).resolved(in: draft) }
        #expect(throws: EditorError.self) { try RuntimeAction.test(groupId: node.id).resolved(in: draft) }
    }

    @Test func theRuntimeSectionIsOnlyInVeersPrompt() {
        let editor = SystemPrompt.build(config: "rules: []")
        let veer = SystemPrompt.build(config: "rules: []", runtime: true)
        #expect(!editor.contains("运行状态操作") && editor.contains("三选一"))
        #expect(veer.contains("四选一") && veer.contains("\"kind\":\"select_fastest\"") && veer.contains("# 解释路由"))
        #expect(SystemPrompt.build(config: "rules: []", search: true, runtime: true).contains("五选一"))
    }

    /// "换到延迟最低的节点" used to stop at the editor's out-of-scope check before the AI saw it.
    @Test func switchingNodesReachesTheAIInVeer() async throws {
        let draft = try ConfigDocument.parse(Self.config)
        let ai = try #require(draft.target(named: "AI"))
        let transport = UnderstandingAndRepairTests.Scripted([
            #"{"understanding":"AI 策略组换到延迟最低的节点","runtime":{"actions":[{"kind":"select_fastest","groupId":"\#(ai.id)"}]}}"#,
        ])
        let engine = EditorEngine(ai: AIClient(transport: transport), validator: UnderstandingAndRepairTests.Pass(),
                                  verifier: UnderstandingAndRepairTests.Verified())
        var request = EditorEngine.Request(prompt: "“AI”换到延迟最低的节点", draft: draft, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")
        request.runtime = true
        guard case .runtime(let steps) = try await engine.run(request, progress: { _ in }) else { Issue.record("expected runtime"); return }
        #expect(steps == [.selectFastest(group: "AI", regions: [])])

        // The editor, and Veer without the AI, still say what they cannot do.
        request.runtime = false
        guard case .outOfScope = try await engine.run(request, progress: { _ in }) else { Issue.record("expected out of scope"); return }
        request.runtime = true
        request.useAI = false
        guard case .outOfScope(let message) = try await engine.run(request, progress: { _ in }) else { Issue.record("expected out of scope"); return }
        #expect(message == LocalIntentParser.runtimeNeedsAIMessage)
    }

    @Test func repliesFollowTheInterfaceLanguage() {
        #expect(!SystemPrompt.build(config: "rules: []").contains("# 回复语言"))
        let english = SystemPrompt.build(config: "rules: []", replyLanguage: "English")
        #expect(english.contains("# 回复语言") && english.contains("English"))
    }

    @Test func runsKnowWhenTheyCanBeUndone() {
        var run = RuntimeRun(steps: [.select(group: "AI", node: "a"), .test(group: "AI")])
        #expect(!run.finished && !run.canUndo)
        run.items[0].state = .done
        run.items[0].undo = .select(group: "AI", node: "b")
        run.items[1].state = .done
        #expect(run.finished && run.canUndo)
        run.undone = true
        #expect(!run.canUndo)
    }
}
