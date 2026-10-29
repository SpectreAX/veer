import Foundation
import Testing
@testable import VeerCore

struct GroupPurposeTests {
    @Test(arguments: ["🚀节点选择", "♻️自动选择", "🐟漏网之鱼", "🇯🇵日本节点", "🇸🇬狮城节点", "🚀 Proxy", "🌏 Auto", "🐠 Final",
                      "🎯 Direct", "🇨🇳 China", "香港自动", "手动切换", "故障转移", "Others"])
    func generalGroups(name: String) {
        #expect(!GroupPurpose.isDedicated(name))
    }

    @Test(arguments: ["学园偶像大师", "🎬媒体解锁", "🤖AI网站", "🛑广告拦截", "📺 GlobalMedia", "🍎 Apple", "🎮 Game", "📟 Telegram", "Netflix"])
    func dedicatedGroups(name: String) {
        #expect(GroupPurpose.isDedicated(name))
    }

    static func route(to target: String) -> ChangeItem {
        ChangeItem(id: 0, kind: .route, subject: "iplark.com", matchType: "DOMAIN-SUFFIX", match: "iplark.com", targetName: target,
                   targetID: "t", replaced: [], rule: "DOMAIN-SUFFIX,iplark.com,\(target)", provider: nil, group: nil)
    }

    @Test func autoModeHoldsTrafficSentIntoAnUnnamedServiceGroup() {
        let passed = ValidationResult(status: .passed, message: "")
        let items = [Self.route(to: "学园偶像大师")]
        #expect(!ExecutionMode.auto.writesAutomatically(items: items, validation: passed, instruction: "iplark.com"))
        #expect(ExecutionMode.auto.heldReason(validation: passed, items: items, instruction: "iplark.com")?.contains("学园偶像大师") == true)
        // Named by the user, it is their choice.
        #expect(ExecutionMode.auto.writesAutomatically(items: items, validation: passed, instruction: "iplark.com 走 学园偶像大师"))
        // A general group needs no naming.
        #expect(ExecutionMode.auto.writesAutomatically(items: [Self.route(to: "🇯🇵日本节点")], validation: passed, instruction: "iplark.com 走日本"))
    }

    @Test func theAISeesOnlyTheVerdict() throws {
        let text = """
        proxies:
          - {name: 🇯🇵 东京 01, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: 学园偶像大师, type: select, proxies: [🇯🇵 东京 01]}
          - {name: 🇯🇵日本节点, type: select, proxies: [🇯🇵 东京 01]}
        rules:
          - MATCH,🇯🇵日本节点
        """
        let document = try ConfigDocument.parse(text)
        let yaml = AnonymizedConfig.make(document: document, regions: [:]).yaml
        #expect(!yaml.contains("学园偶像大师"))
        #expect(yaml.components(separatedBy: "用途: 专用").count == 2)
    }
}
