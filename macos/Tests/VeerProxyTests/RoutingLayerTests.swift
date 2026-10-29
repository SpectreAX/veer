import Foundation
import Testing
@testable import VeerCore
import Yams
@testable import VeerProxy

struct RoutingLayerTests {
    static let profile = """
    proxies:
      - {name: 🇯🇵 东京 01, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 节点选择, type: select, proxies: [日本, 🇺🇸 洛杉矶 01]}
      - {name: 日本, type: select, proxies: [🇯🇵 东京 01, 🇯🇵 大阪 02]}
      - {name: 美国, type: select, proxies: [🇺🇸 洛杉矶 01]}
      - {name: 更多, type: select, use: [provider], proxies: [🇺🇸 洛杉矶 01]}
    proxy-providers:
      provider: {type: http, url: "https://sub.example.invalid/p", path: ./providers/p.yaml}
    rules:
      - DOMAIN-SUFFIX,direct-to-node.example,🇯🇵 东京 01
      - MATCH,节点选择
    """

    static func edit(_ prompt: String, on base: String, _ operations: (ConfigDocument) -> [EditPlan.Operation]) throws -> RoutingLayer.Edit {
        let document = try ConfigDocument.parse(base)
        let plan = EditPlan(operations: operations(document))
        let result = try PlanApplier.apply(plan, to: document)
        return RoutingLayer.Edit(source: .agent, prompt: prompt, plan: plan, accepted: Set(plan.operations.indices), items: result.items, base: base)
    }

    static func names(_ list: Any?) -> [String] { (list as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [] }

    @Test func anEmptyLayerLeavesTheProfileAsItIs() throws {
        let effective = try RoutingLayer().apply(to: Self.profile)
        #expect(effective.text == Self.profile && effective.replay == nil)
    }

    @Test func enabledEditsReplayAndDisabledOnesDoNot() throws {
        var edit = try Self.edit("Netflix 走日本", on: Self.profile) {
            [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: $0.target(named: "日本")!.id)]
        }
        var layer = RoutingLayer(edits: [edit])
        #expect(try ConfigDocument.parse(layer.apply(to: Self.profile).text).rules.contains("DOMAIN-SUFFIX,netflix.com,日本"))
        edit.enabled = false
        layer.edits = [edit]
        #expect(try !ConfigDocument.parse(layer.apply(to: Self.profile).text).rules.contains("DOMAIN-SUFFIX,netflix.com,日本"))
    }

    @Test func aRefreshThatLostTheTargetReportsAConflict() throws {
        let edit = try Self.edit("走美国", on: Self.profile) {
            [.route(matchType: "DOMAIN-SUFFIX", match: "hulu.com", targetId: $0.target(named: "美国")!.id)]
        }
        let refreshed = Self.profile.replacingOccurrences(of: "  - {name: 美国, type: select, proxies: [🇺🇸 洛杉矶 01]}\n", with: "")
        let effective = try RoutingLayer(edits: [edit]).apply(to: refreshed)
        #expect(effective.conflictCount == 1)
        #expect(try !ConfigDocument.parse(effective.text).rules.contains { $0.contains("hulu.com") })
    }

    @Test func excludedNodesLeaveProxiesAndGroups() throws {
        let effective = try RoutingLayer(excludedNodes: ["🇯🇵 大阪 02", "🇺🇸 洛杉矶 01"]).apply(to: Self.profile)
        let config = try #require(try Yams.load(yaml: effective.text) as? [String: Any])
        #expect(Self.names(config["proxies"]) == ["🇯🇵 东京 01"])
        let groups = try #require(config["proxy-groups"] as? [[String: Any]])
        #expect(groups.first { $0["name"] as? String == "节点选择" }?["proxies"] as? [String] == ["日本"])
        #expect(groups.first { $0["name"] as? String == "日本" }?["proxies"] as? [String] == ["🇯🇵 东京 01"])
        // Emptied: falls back to DIRECT. Fed by a provider: may be empty here.
        #expect(groups.first { $0["name"] as? String == "美国" }?["proxies"] as? [String] == ["DIRECT"])
        #expect(groups.first { $0["name"] as? String == "更多" }?["proxies"] as? [String] == [])
        #expect(effective.emptiedGroups == ["美国"] && effective.keptNodes.isEmpty)
    }

    @Test func flagEmojiStayReadableWhenTheLayerRewritesTheFile() throws {
        let effective = try RoutingLayer(excludedNodes: ["🇯🇵 大阪 02"]).apply(to: Self.profile)
        #expect(effective.text.contains("🇯🇵 东京 01") && !effective.text.contains("\\U0001F1"))
        let exported = try RuntimeConfig.export(profile: effective.text, settings: RuntimeSettings())
        #expect(exported.contains("🇺🇸 洛杉矶 01") && !exported.contains("\\U0001F1"))
    }

    @Test func aNodeARuleNamesStays() throws {
        let effective = try RoutingLayer(excludedNodes: ["🇯🇵 东京 01"]).apply(to: Self.profile)
        #expect(effective.keptNodes == ["🇯🇵 东京 01"])
        #expect(effective.text == Self.profile)
    }

    @Test func exclusionsSurviveARefreshByName() throws {
        let refreshed = Self.profile.replacingOccurrences(of: "  - {name: 🇺🇸 洛杉矶 01", with: "  - {name: 🇭🇰 香港 01, type: ss, server: hk.example.invalid, port: 1, cipher: aes-128-gcm, password: p}\n  - {name: 🇺🇸 洛杉矶 01")
        let effective = try RoutingLayer(excludedNodes: ["🇯🇵 大阪 02"]).apply(to: refreshed)
        let config = try #require(try Yams.load(yaml: effective.text) as? [String: Any])
        #expect(Self.names(config["proxies"]) == ["🇯🇵 东京 01", "🇭🇰 香港 01", "🇺🇸 洛杉矶 01"])
    }

    @Test func theEffectiveConfigPassesMihomo() async throws {
        let validator = MihomoValidator(binary: try #require(CoreProcessTests.binary, "needs VEER_MIHOMO_BIN"))
        let edit = try Self.edit("Netflix 走日本", on: Self.profile) {
            [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: $0.target(named: "日本")!.id)]
        }
        let layer = RoutingLayer(edits: [edit], excludedNodes: ["🇺🇸 洛杉矶 01"])
        let profile = Self.profile.replacingOccurrences(of: "  - {name: 更多, type: select, use: [provider], proxies: [🇺🇸 洛杉矶 01]}\n", with: "")
            .replacingOccurrences(of: "proxy-providers:\n  provider: {type: http, url: \"https://sub.example.invalid/p\", path: ./providers/p.yaml}\n", with: "")
        let exported = try RuntimeConfig.export(profile: layer.apply(to: profile).text, settings: RuntimeSettings())
        #expect(!exported.contains("external-controller") && !exported.contains("secret"))
        #expect(await validator.validate(exported).status == .passed)
    }

    @Test func layersRoundTripAndAnEmptyOneLeavesNoFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VeerPaths(root: root)
        let store = RoutingStore(paths: paths)
        let id = UUID()
        let edit = try Self.edit("Netflix 走日本", on: Self.profile) {
            [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: $0.target(named: "日本")!.id)]
        }
        let layer = RoutingLayer(edits: [edit], excludedNodes: ["🇯🇵 大阪 02"])
        try store.save(layer, for: id)
        // Dates keep whole seconds.
        #expect(RoutingStore(paths: paths).load(id).edits.map(\.id) == [edit.id])
        #expect(RoutingStore(paths: paths).load(id).excludedNodes == ["🇯🇵 大阪 02"])
        try store.save(RoutingLayer(), for: id)
        #expect(!FileManager.default.fileExists(atPath: paths.routing.appendingPathComponent("\(id.uuidString).json").path))
        #expect(store.load(id) == RoutingLayer())
    }
}
