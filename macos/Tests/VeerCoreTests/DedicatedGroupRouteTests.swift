import Foundation
import Testing
@testable import VeerCore

struct DedicatedGroupRouteTests {
    private let config = """
    proxies:
      - {name: 日本节点, type: ss, server: a.example, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 美国节点, type: ss, server: b.example, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: mini4k, type: select, proxies: [日本节点, 美国节点]}
      - {name: 媒体测速, type: url-test, proxies: [日本节点, 美国节点], url: "https://a.example", interval: 300}
      - {name: 节点选择, type: select, proxies: [日本节点, 美国节点]}
      - {name: 已有直连, type: select, proxies: [DIRECT, 日本节点]}
    rules:
      - DOMAIN-SUFFIX,mini4k.net,mini4k
      - DOMAIN-SUFFIX,fast.example,媒体测速
      - DOMAIN-SUFFIX,general.example,节点选择
      - DOMAIN-SUFFIX,other.example,已有直连
      - MATCH,mini4k
    """

    private func draft() throws -> ConfigDocument { try ConfigDocument.parse(config) }

    private func direct(_ match: String, in draft: ConfigDocument) -> EditPlan {
        EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: match, targetId: draft.target(named: "DIRECT")!.id)])
    }

    private final class Validator: ConfigValidating, @unchecked Sendable {
        var versionDescription: String? { nil }
        func validate(_ yaml: String) async -> ValidationResult { ValidationResult(status: .passed, message: "") }
    }

    private func request(_ prompt: String, _ draft: ConfigDocument, mode: ExecutionMode = .manual, runtime: Bool = true) -> EditorEngine.Request {
        var request = EditorEngine.Request(prompt: prompt, draft: draft, regions: [:], useAI: false, settings: AISettings(), apiKey: nil)
        request.mode = mode
        request.runtime = runtime
        return request
    }

    @Test func aDomainWithItsOwnSelectGroupConflicts() throws {
        let draft = try draft()
        #expect(DedicatedGroupRoute.conflict(in: direct("mini4k.net", in: draft), draft: draft)
            == .init(group: "mini4k", match: "mini4k.net"))
        #expect(DedicatedGroupRoute.conflict(in: direct("www.mini4k.net", in: draft), draft: draft)?.group == "mini4k")
    }

    @Test func otherCasesGoAhead() throws {
        let draft = try draft()
        // A general group, an automatic one, and a domain only the final MATCH catches.
        #expect(DedicatedGroupRoute.conflict(in: direct("general.example", in: draft), draft: draft) == nil)
        #expect(DedicatedGroupRoute.conflict(in: direct("fast.example", in: draft), draft: draft) == nil)
        #expect(DedicatedGroupRoute.conflict(in: direct("unlisted.example", in: draft), draft: draft) == nil)
        // Somewhere other than DIRECT.
        let elsewhere = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "mini4k.net", targetId: draft.target(named: "节点选择")!.id)])
        #expect(DedicatedGroupRoute.conflict(in: elsewhere, draft: draft) == nil)
        // With other work in the plan.
        var mixed = direct("mini4k.net", in: draft)
        mixed.operations.append(.removeRule(matchType: "DOMAIN-SUFFIX", match: "general.example"))
        #expect(DedicatedGroupRoute.conflict(in: mixed, draft: draft) == nil)
    }

    @Test func unrelatedMemberEditsDoNotSwitchToDirect() throws {
        let draft = try draft()
        let direct = try #require(draft.target(named: "DIRECT")?.id)
        for name in ["已有直连", "mini4k"] {
            let id = try #require(draft.target(named: name)?.id)
            let plan = EditPlan(operations: [.groupMembers(targetId: id, members: [direct])])
            #expect(DedicatedGroupRoute.groupToSwitch(after: "修改成员", in: draft, plan: plan, accepted: [0], mode: .full) == nil)
        }
    }

    @Test func theEngineAsksInsteadOfReplacingTheRule() async throws {
        let draft = try draft()
        let engine = EditorEngine(validator: Validator())
        let output = try await engine.handle(.plan(direct("mini4k.net", in: draft)), request: request("mini4k.net 走直连", draft)) { _ in }
        guard case let .clarification(question, options) = output else { Issue.record("expected a question"); return }
        #expect(question.contains("mini4k"))
        #expect(options.count == 2)
    }

    @Test func fullPermissionKeepsTheGroupWithoutAsking() async throws {
        let draft = try draft()
        let engine = EditorEngine(validator: Validator())
        let output = try await engine.handle(.plan(direct("mini4k.net", in: draft)), request: request("mini4k.net 走直连", draft, mode: .full)) { _ in }
        guard case let .proposal(plan, _, candidate, _) = output else { Issue.record("expected a proposal"); return }
        guard case let .groupMembers(_, members) = plan.operations[0] else { Issue.record("expected a member edit"); return }
        #expect(members.count == 3)
        #expect(DedicatedGroupRoute.groupToSwitch(after: "mini4k.net 走直连", in: draft, plan: plan, accepted: [0], mode: .full) == "mini4k")
        #expect(DedicatedGroupRoute.groupToSwitch(after: "mini4k.net 走直连", in: draft, plan: plan, accepted: [], mode: .full) == nil)
        // The domain's own rule is left in place.
        #expect(candidate.contains("DOMAIN-SUFFIX,mini4k.net,mini4k"))
        #expect(try ConfigDocument.parse(candidate).groupMembers["mini4k"] == ["日本节点", "美国节点", "DIRECT"])
    }

    @Test func theFirstOptionAddsDirectWithoutTheAI() async throws {
        let draft = try draft()
        let conflict = DedicatedGroupRoute.Conflict(group: "mini4k", match: "mini4k.net")
        let prompt = try #require(DedicatedGroupRoute.options(for: conflict)[0].prompt)
        let output = try await EditorEngine(validator: Validator()).run(request(prompt, draft)) { _ in }
        guard case let .proposal(plan, _, candidate, _) = output else { Issue.record("expected a proposal"); return }
        #expect(DedicatedGroupRoute.groupToSwitch(after: prompt, in: draft, plan: plan, accepted: [0], mode: .manual) == "mini4k")
        #expect(try ConfigDocument.parse(candidate).groupMembers["mini4k"]?.last == "DIRECT")
    }

    @Test func theSecondOptionReplacesTheRuleWithoutAskingAgain() async throws {
        let draft = try draft()
        let conflict = DedicatedGroupRoute.Conflict(group: "mini4k", match: "mini4k.net")
        let prompt = try #require(DedicatedGroupRoute.options(for: conflict)[1].prompt)
        let output = try await EditorEngine(validator: Validator()).run(request(prompt, draft)) { _ in }
        guard case let .proposal(plan, _, candidate, _) = output else { Issue.record("expected a proposal"); return }
        #expect(DedicatedGroupRoute.groupToSwitch(after: prompt, in: draft, plan: plan, accepted: [0], mode: .full) == nil)
        let rules = try ConfigDocument.parse(candidate).rules
        #expect(rules.contains("DOMAIN-SUFFIX,mini4k.net,DIRECT"))
        #expect(!rules.contains("DOMAIN-SUFFIX,mini4k.net,mini4k"))
    }

    @Test func aGroupThatHasDirectOnlySwitches() async throws {
        let draft = try draft()
        let prompt = DedicatedGroupRoute.useDirectPrompt(group: "已有直连")
        let engine = EditorEngine(validator: Validator())
        let output = try await engine.run(request(prompt, draft)) { _ in }
        guard case let .runtime(steps) = output else { Issue.record("expected an action"); return }
        #expect(steps == [.select(group: "已有直连", node: "DIRECT")])
        // Another profile than the one running: it can only say so.
        let elsewhere = try await engine.run(request(prompt, draft, runtime: false)) { _ in }
        guard case .noChange = elsewhere else { Issue.record("expected a note"); return }
    }

    @Test func ordinaryInstructionsAreNotChoices() throws {
        #expect(DedicatedGroupRoute.choice(for: "mini4k.net 走直连", in: try draft()) == nil)
        #expect(DedicatedGroupRoute.choice(for: "", in: try draft()) == nil)
    }
}
