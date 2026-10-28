import Foundation
import Testing
@testable import VeerCore

/// Replaying written edits onto refreshed content (a subscription update).
struct EditReplayTests {
    static let original = """
    proxies:
      - {name: 🇯🇵 东京 01, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 节点选择, type: select, proxies: [🇯🇵 东京 01, 🇺🇸 洛杉矶 01]}
      - {name: 日本, type: select, proxies: [🇯🇵 东京 01]}
    rules:
      - DOMAIN-SUFFIX,old.example,节点选择
      - MATCH,节点选择
    """

    /// The same subscription a week later: a new group first (so every id shifts), a new Japan node.
    static let refreshed = """
    proxies:
      - {name: 🇭🇰 香港 01, type: ss, server: hk1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 东京 01, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 自动选择, type: url-test, proxies: [🇭🇰 香港 01, 🇯🇵 东京 01], url: "https://www.gstatic.com/generate_204", interval: 300}
      - {name: 节点选择, type: select, proxies: [自动选择, 🇯🇵 东京 01, 🇺🇸 洛杉矶 01]}
      - {name: 日本, type: select, proxies: [🇯🇵 东京 01, 🇯🇵 大阪 02]}
    rules:
      - MATCH,节点选择
    """

    /// Writes `operations` onto `base` the way a reviewed proposal is written.
    static func edit(_ prompt: String, _ operations: (ConfigDocument) -> [EditPlan.Operation], on base: String) throws -> (EditReplay.Edit, String) {
        let document = try ConfigDocument.parse(base)
        let plan = EditPlan(operations: operations(document))
        let result = try PlanApplier.apply(plan, to: document)
        let edit = EditReplay.Edit(id: UUID(), prompt: prompt, plan: plan, accepted: Set(plan.operations.indices),
                                   items: result.items, base: base)
        return (edit, result.candidate)
    }

    static func id(_ name: String, in document: ConfigDocument) -> String { document.target(named: name)!.id }

    @Test func routesFollowExitNamesWhenIdsShift() throws {
        let (edit, _) = try Self.edit("Netflix 走日本", { [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: Self.id("日本", in: $0))] },
                                      on: Self.original)
        let result = EditReplay.replay([edit], onto: Self.refreshed)
        let rules = try ConfigDocument.parse(result.text).rules
        #expect(rules.contains("DOMAIN-SUFFIX,netflix.com,日本"))
        #expect(result.edits[0].items.map(\.outcome) == [.applied])
    }

    @Test func aMissingExitIsAConflictAndTheRestStillApplies() throws {
        let (edit, _) = try Self.edit("两条", {
            [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: Self.id("日本", in: $0)),
             .route(matchType: "DOMAIN-SUFFIX", match: "openai.com", targetId: Self.id("🇺🇸 洛杉矶 01", in: $0))]
        }, on: Self.original)
        let withoutJapan = Self.refreshed
            .replacingOccurrences(of: "  - {name: 日本, type: select, proxies: [🇯🇵 东京 01, 🇯🇵 大阪 02]}\n", with: "")
        let result = EditReplay.replay([edit], onto: withoutJapan)
        let outcomes = result.edits[0].items.map(\.outcome)
        #expect(outcomes[0] == .conflict("出口“日本”不在新内容中。"))
        #expect(outcomes[1] == .applied)
        #expect(try ConfigDocument.parse(result.text).rules.contains("DOMAIN-SUFFIX,openai.com,🇺🇸 洛杉矶 01"))
        #expect(result.conflictCount == 1 && result.appliedCount == 1)
    }

    @Test func removalsOfRulesTheNewContentNoLongerHasAreUnchanged() throws {
        let (edit, _) = try Self.edit("删掉 old.example", { _ in [.removeRule(matchType: "DOMAIN-SUFFIX", match: "old.example")] },
                                      on: Self.original)
        let result = EditReplay.replay([edit], onto: Self.refreshed)
        #expect(result.edits[0].items.map(\.outcome) == [.unchanged("新内容里已经没有这条规则。")])
        #expect(result.text == Self.refreshed)
    }

    @Test func aChangeTheNewContentAlreadyHasIsUnchanged() throws {
        let (edit, _) = try Self.edit("old.example 走节点选择", {
            [.route(matchType: "DOMAIN-SUFFIX", match: "old.example", targetId: Self.id("🇺🇸 洛杉矶 01", in: $0))]
        }, on: Self.original)
        let already = Self.refreshed.replacingOccurrences(of: "rules:\n", with: "rules:\n  - DOMAIN-SUFFIX,old.example,🇺🇸 洛杉矶 01\n")
        let result = EditReplay.replay([edit], onto: already)
        #expect(result.edits[0].items.map(\.outcome) == [.unchanged("新内容里已经是这样了。")])
    }

    @Test func aRegionalGroupPicksUpTheNewNodesAndItsRoutesComeWithIt() throws {
        let (edit, _) = try Self.edit("新建日本节点组，YouTube 走它", { _ in
            [.group(.init(id: "new-1", name: "日本节点组", regions: [.jp])),
             .route(matchType: "DOMAIN-SUFFIX", match: "youtube.com", targetId: "new-1")]
        }, on: Self.original.replacingOccurrences(of: "  - {name: 日本, type: select, proxies: [🇯🇵 东京 01]}\n", with: ""))
        let noJapanGroup = Self.refreshed
            .replacingOccurrences(of: "  - {name: 日本, type: select, proxies: [🇯🇵 东京 01, 🇯🇵 大阪 02]}\n", with: "")
        let result = EditReplay.replay([edit], onto: noJapanGroup)
        #expect(result.edits[0].items.map(\.outcome) == [.applied, .applied])
        #expect(result.text.contains("日本节点组"))
        #expect(result.text.contains("🇯🇵 大阪 02"))
        #expect(try ConfigDocument.parse(result.text).rules.contains("DOMAIN-SUFFIX,youtube.com,日本节点组"))
    }

    @Test func aGroupCreatedUnderAnotherNameKeepsLaterEditsPointingAtIt() throws {
        let (first, draft) = try Self.edit("新建 AI 组", { _ in [.group(.init(id: "new-1", name: "AI", members: [], excludeRegions: [.hk]))] },
                                           on: Self.original)
        let (second, _) = try Self.edit("ChatGPT 走 AI", { [.route(matchType: "DOMAIN-SUFFIX", match: "openai.com", targetId: Self.id("AI", in: $0))] },
                                        on: draft)
        // The new subscription brings its own group called AI.
        let clash = Self.refreshed.replacingOccurrences(of: "proxy-groups:\n", with: "proxy-groups:\n  - {name: AI, type: select, proxies: [🇭🇰 香港 01]}\n")
        let result = EditReplay.replay([first, second], onto: clash)
        guard case .adjusted(let note) = result.edits[0].items[0].outcome else {
            Issue.record("expected the group to be created under another name, got \(result.edits[0].items[0].outcome)")
            return
        }
        let created = result.edits[0].items[0].item.group?.name ?? "AI"
        #expect(note.contains("新建为"))
        let rules = try ConfigDocument.parse(result.text).rules
        #expect(!rules.contains("DOMAIN-SUFFIX,openai.com,AI"), "must not point at the subscription's own AI group")
        #expect(rules.contains { $0.hasPrefix("DOMAIN-SUFFIX,openai.com,") && $0 != "DOMAIN-SUFFIX,openai.com,AI" }, "\(created) \(rules)")
    }

    @Test func onlyWrittenProposalsAreReplayedInOrder() throws {
        var session = Session(title: "订阅", source: .subscription(host: "sub.example.invalid"), text: Self.original)
        func turn(_ prompt: String, status: Turn.ProposalStatus) -> Turn {
            var turn = Turn(prompt: prompt, mode: .local, steps: [])
            turn.outcome = .proposal(.init(plan: EditPlan(operations: [.removeRule(matchType: "DOMAIN-SUFFIX", match: "old.example")]),
                                           items: [], accepted: [0], baseDraft: Self.original, candidate: Self.original,
                                           validation: .init(status: .passed, message: ""), status: status))
            return turn
        }
        session.turns = [turn("一", status: .written), turn("二", status: .undone), turn("三", status: .discarded), turn("四", status: .written)]
        #expect(EditReplay.edits(of: session).map(\.prompt) == ["一", "四"])
    }

    @Test func sessionsSavedBeforeImportOptionsStillLoad() throws {
        var session = Session(title: "旧会话", source: .pasted, text: Self.original)
        session.importOptions = ImportOptions(include: "日本")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        object.removeValue(forKey: "importOptions")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.importOptions == nil)
        #expect(decoded.originalText == Self.original)
    }
}
