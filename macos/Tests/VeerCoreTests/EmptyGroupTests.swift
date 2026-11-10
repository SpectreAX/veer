import Testing
@testable import VeerCore

struct EmptyGroupTests {
    static let invalid = """
    proxies: []
    proxy-groups:
      - {name: Proxy, type: select, proxies: [Auto, DIRECT]}
      - {name: Auto, type: url-test, proxies: []}
    rules:
      - MATCH,Proxy
    """

    @Test(arguments: ["", "proxies: []", "use: []", "proxies: [], use: []"])
    func importsRejectGroupsWithoutAnySource(fields: String) {
        let text = "proxy-groups:\n  - {name: Auto, type: url-test\(fields.isEmpty ? "" : ", " + fields)}\n"
        #expect { try ConfigImporter.normalize(text) } throws: {
            ($0 as? EditorError)?.message.contains("Auto”没有节点或 Provider") == true
        }
    }

    @Test func anEmptyGroupCanStillBeOpenedAndRepairedByTheEditor() throws {
        let document = try ConfigDocument.parse(Self.invalid)
        #expect(document.groupMembers["Auto"] == [])
        let target = try #require(document.target(named: "Auto"))
        let direct = try #require(document.target(named: "DIRECT"))
        let plan = EditPlan(operations: [.groupMembers(targetId: target.id, members: [direct.id])])
        let repaired = try PlanApplier.apply(plan, to: document).candidate
        #expect(try ConfigImporter.normalize(repaired).text == repaired)
    }

    @Test(arguments: ["proxies: [DIRECT]", "use: [remote]", "include-all: true", "include-all-proxies: true", "include-all-providers: true"])
    func validMemberSourcesStayVerbatim(fields: String) throws {
        let text = "proxy-groups:\n  - {name: Auto, type: select, \(fields)}\n"
        #expect(try ConfigImporter.normalize(text).text == text)
    }
}
