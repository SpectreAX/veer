import Foundation
import Testing
@testable import VeerCore

struct AppRoutingAgentTests {
    static let config = RuntimeActionTests.config
    static let home = "/Users/someone"
    static let chat = AppIdentity(kind: .bundle, name: "Chatty", bundleID: "com.example.chatty", bundlePath: "\(home)/Applications/Chatty.app",
                                  executablePath: "\(home)/Applications/Chatty.app/Contents/MacOS/Chatty", flavor: .electron)

    static func lookup(_ apps: [AppIdentity], rules: [AppRule] = []) -> @Sendable (String?) async -> AppLookupResult {
        { _ in AppLookupResult(apps: apps, running: [], rules: rules, state: "规则模式，应用规则正在生效。") }
    }

    @Test func repliesDecodeStrictly() throws {
        #expect(try EditPlan.decodeReply(#"{"apps":{"query":"chat"}}"#) == .apps("chat"))
        #expect(try EditPlan.decodeReply(#"{"apps":{}}"#) == .apps(nil))
        let domain = #"{"matchType":"domain-suffix","value":"a.example","target":"REJECT"}"#
        let routes = try EditPlan.decodeReply(#"{"appRoutes":{"changes":[{"app":"app-1","target":"DIRECT","domains":[\#(domain)]}]}}"#)
        #expect(routes == .appRoutes([AppRouteRequest(app: "app-1", target: "DIRECT",
                                                      domains: [.init(matchType: "DOMAIN-SUFFIX", value: "a.example", target: "REJECT")], remove: false)]))
        // Unknown fields, mixed replies, empty or too many changes, and a change that does nothing are refused.
        for bad in [#"{"apps":{"path":"/x"}}"#, #"{"apps":{},"clarification":"?"}"#, #"{"appRoutes":{"changes":[]}}"#,
                    #"{"appRoutes":{"changes":[{"app":"app-1"}]}}"#, #"{"appRoutes":{"changes":[{"app":"app-1","bundleID":"x","target":"DIRECT"}]}}"#] {
            #expect(throws: EditorError.self) { try EditPlan.decodeReply(bad) }
        }
        let nine = Array(repeating: #"{"app":"app-1","remove":true}"#, count: 9).joined(separator: ",")
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"appRoutes":{"changes":[\#(nine)]}}"#) }
    }

    /// The model looks up, gets a reference, and proposes by it; exits come back as real names.
    @Test func lookupThenProposalResolvesToRealAppsAndExits() async throws {
        let draft = try ConfigDocument.parse(Self.config)
        let transport = UnderstandingAndRepairTests.Scripted([
            #"{"understanding":"先查 Chatty","apps":{"query":"chatty"}}"#,
            #"{"understanding":"Chatty 走策略组1","appRoutes":{"changes":[{"app":"app-1","target":"策略组1"}]}}"#,
        ])
        let engine = EditorEngine(ai: AIClient(transport: transport), validator: UnderstandingAndRepairTests.Pass(),
                                  verifier: UnderstandingAndRepairTests.Verified())
        var request = EditorEngine.Request(prompt: "Chatty 走 AI", draft: draft, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")
        request.appLookup = Self.lookup([Self.chat])
        guard case .appRouting(let changes) = try await engine.run(request, progress: { _ in }) else { Issue.record("expected app routing"); return }
        #expect(changes == [AppRouteChange(app: Self.chat, target: .policy("AI"))])

        // What Veer told the model: a reference and a name, no path; the system prompt has the tools.
        let messages = transport.requests.last?["messages"] as? [[String: String]] ?? []
        let answer = messages.last?["content"] ?? ""
        #expect(answer.contains("app-1 Chatty") && !answer.contains("/Users/") && !answer.contains("Applications/"))
        #expect((messages.first?["content"] ?? "").contains("# 应用分流（本机应用，按进程）"))
    }

    @Test func referencesThatWereNeverGivenOutAreSentBack() async throws {
        let draft = try ConfigDocument.parse(Self.config)
        let transport = UnderstandingAndRepairTests.Scripted([
            #"{"understanding":"x","appRoutes":{"changes":[{"app":"app-7","target":"DIRECT"}]}}"#,
            #"{"understanding":"x","appRoutes":{"changes":[{"app":"app-7","target":"DIRECT"}]}}"#,
        ])
        let engine = EditorEngine(ai: AIClient(transport: transport), validator: UnderstandingAndRepairTests.Pass(),
                                  verifier: UnderstandingAndRepairTests.Verified())
        var request = EditorEngine.Request(prompt: "Chatty 直连", draft: draft, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")
        request.appLookup = Self.lookup([Self.chat])
        await #expect(throws: EditorError.self) { try await engine.run(request, progress: { _ in }) }
        // Without the tools (the editor, iOS) the same reply is refused too.
        request.appLookup = nil
        await #expect(throws: EditorError.self) { try await engine.run(request, progress: { _ in }) }
        #expect(!SystemPrompt.build(config: "rules: []").contains("appRoutes"))
    }

    @Test func proposalsApplyToRulesInPlace() {
        let other = AppIdentity(kind: .executable, name: "curl", executablePath: "/usr/bin/curl", flavor: .commandLine)
        let rules = [AppRule(app: Self.chat, target: .direct, enabled: false), AppRule(app: other, target: .reject)]
        let proposal = AppRoutingProposal(changes: [AppRouteChange(app: Self.chat, target: .policy("AI")),
                                                    AppRouteChange(app: other, target: nil, remove: true),
                                                    AppRouteChange(app: AppIdentity(kind: .executable, name: "git", executablePath: "/usr/bin/git"),
                                                                   target: .direct)])
        let result = proposal.applying(to: rules)
        #expect(result.map(\.app.name) == ["Chatty", "git"])
        #expect(result[0].id == rules[0].id && result[0].target == .policy("AI") && result[0].enabled)
        #expect(result[1].source == .agent)
    }

    @Test func autoModeHoldsBlocksAndRemovals() {
        let passed = ValidationResult(status: .passed, message: "")
        let route = [AppRouteChange(app: Self.chat, target: .direct)]
        let block = [AppRouteChange(app: Self.chat, target: .reject)]
        #expect(ExecutionMode.auto.appliesAppRoutingAutomatically(route, validation: passed))
        #expect(!ExecutionMode.auto.appliesAppRoutingAutomatically(block, validation: passed))
        #expect(!ExecutionMode.auto.appliesAppRoutingAutomatically(route, validation: nil))
        #expect(!ExecutionMode.manual.appliesAppRoutingAutomatically(route, validation: passed))
        #expect(ExecutionMode.full.appliesAppRoutingAutomatically(block, validation: ValidationResult(status: .unavailable, message: "")))
    }

    @Test func processPathsNeverCarryTheUsersName() {
        let document = try? ConfigDocument.parse(Self.config.replacingOccurrences(
            of: "rules:\n", with: "rules:\n  - PROCESS-PATH-WILDCARD,/Users/someone/Applications/Chatty.app/*,DIRECT\n"))
        let shared = document.map { AnonymizedConfig.make(document: $0, regions: [:], shareRuleLiterals: true).yaml } ?? ""
        #expect(shared.contains("~/Applications/Chatty.app/*") && !shared.contains("someone"))
    }
}
