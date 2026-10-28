import Foundation
import Testing
@testable import VeerCore

/// Editing the members of an existing proxy group.
struct GroupMembersTests {
    static let config = """
    # 机场配置
    proxies:
      - {name: 🇯🇵 东京 01, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-providers:
      extra: {type: http, url: "https://example.invalid/sub", path: ./extra.yaml, interval: 3600}
    proxy-groups:
      # 手动选择
      - name: 节点选择
        type: select
        proxies:
          - 🇯🇵 东京 01
          - 🇺🇸 洛杉矶 01
      - {name: 日本, type: url-test, url: "https://www.gstatic.com/generate_204", interval: 300, proxies: [🇯🇵 东京 01]}
      - name: 备用
        type: select
        use: [extra]
    rules:
      - DOMAIN-SUFFIX,example.com,日本 # 示例
      - MATCH,节点选择
    """

    static func ids(_ names: [String], in document: ConfigDocument) -> [String] { names.map { document.target(named: $0)!.id } }

    @Test func onlyTheEditedGroupsMembersChange() throws {
        let document = try ConfigDocument.parse(Self.config)
        let plan = EditPlan(operations: [.groupMembers(targetId: document.target(named: "节点选择")!.id,
                                                       members: Self.ids(["🇺🇸 洛杉矶 01", "日本", "🇯🇵 大阪 02"], in: document))])
        let result = try PlanApplier.apply(plan, to: document)
        let after = try ConfigDocument.parse(result.candidate)
        #expect(after.groupMembers["节点选择"] == ["🇺🇸 洛杉矶 01", "日本", "🇯🇵 大阪 02"])
        #expect(after.groupMembers["日本"] == ["🇯🇵 东京 01"])
        #expect(after.rules == document.rules)
        // Every line outside the edited group is byte for byte the same, comments included.
        let before = Self.config.components(separatedBy: "\n")
        let kept = result.candidate.components(separatedBy: "\n")
        #expect(kept.contains("  # 手动选择") && kept.contains("  - DOMAIN-SUFFIX,example.com,日本 # 示例"))
        #expect(kept.contains(before.first { $0.contains("{name: 日本") }!))
        let item = try #require(result.items.first)
        #expect(item.kind == .groupMembers && item.subject == "节点选择" && item.replaced == ["🇯🇵 东京 01", "🇺🇸 洛杉矶 01"])
    }

    @Test func aGroupWrittenOnOneLineCanBeEditedToo() throws {
        let document = try ConfigDocument.parse(Self.config)
        let plan = EditPlan(operations: [.groupMembers(targetId: document.target(named: "日本")!.id,
                                                       members: Self.ids(["🇯🇵 东京 01", "🇯🇵 大阪 02"], in: document))])
        let after = try ConfigDocument.parse(try PlanApplier.apply(plan, to: document).candidate)
        #expect(after.groupMembers["日本"] == ["🇯🇵 东京 01", "🇯🇵 大阪 02"])
        #expect(after.targets.first { $0.name == "日本" }?.type == "url-test")
    }

    @Test func emptyMembersNeedAProviderAndAGroupCannotContainItself() throws {
        let document = try ConfigDocument.parse(Self.config)
        let backup = document.target(named: "备用")!.id
        let withProvider = try PlanApplier.apply(EditPlan(operations: [.groupMembers(targetId: backup, members: [])]), to: document)
        #expect(try ConfigDocument.parse(withProvider.candidate).groupMembers["备用"] == [])
        let main = document.target(named: "节点选择")!.id
        #expect(throws: EditorError("策略组“节点选择”至少需要一个成员。")) {
            try PlanApplier.apply(EditPlan(operations: [.groupMembers(targetId: main, members: [])]), to: document)
        }
        #expect(throws: EditorError("策略组“节点选择”不能包含它自己。")) {
            try PlanApplier.apply(EditPlan(operations: [.groupMembers(targetId: main, members: [main])]), to: document)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
    func mihomoAcceptsTheEditedGroups() async throws {
        let document = try ConfigDocument.parse(Self.config)
        let plan = EditPlan(operations: [
            .groupMembers(targetId: document.target(named: "节点选择")!.id, members: Self.ids(["日本", "🇺🇸 洛杉矶 01"], in: document)),
            .groupMembers(targetId: document.target(named: "日本")!.id, members: Self.ids(["🇯🇵 东京 01", "🇯🇵 大阪 02"], in: document)),
        ])
        let check = await MihomoValidator().validate(try PlanApplier.apply(plan, to: document).candidate)
        #expect(check.status == .passed, "\(check.message)")
    }

    @Test func memberEditsReplayByNameAndSkipMissingMembers() throws {
        let document = try ConfigDocument.parse(Self.config)
        let plan = EditPlan(operations: [.groupMembers(targetId: document.target(named: "节点选择")!.id,
                                                       members: Self.ids(["🇯🇵 大阪 02", "🇺🇸 洛杉矶 01"], in: document))])
        let result = try PlanApplier.apply(plan, to: document)
        let edit = EditReplay.Edit(id: UUID(), prompt: "调整节点选择", plan: plan, accepted: [0], items: result.items, base: Self.config)
        // The provider dropped 大阪 02 from the new subscription.
        let refreshed = Self.config.replacingOccurrences(of: "  - {name: 🇯🇵 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}\n", with: "")
        let replay = EditReplay.replay([edit], onto: refreshed)
        #expect(replay.edits[0].items[0].outcome == .adjusted("成员 “🇯🇵 大阪 02” 不在新内容中，已略过。"))
        #expect(try ConfigDocument.parse(replay.text).groupMembers["节点选择"] == ["🇺🇸 洛杉矶 01"])
    }
}
