import Testing
import VeerCore
@testable import VeerProxy

struct EmptyGroupRuntimeTests {
    @Test(arguments: [false, true])
    func bothRuntimePathsRejectEmptyGroups(anchors: Bool) {
        let profile = """
        \(anchors ? "shared: &shared {type: url-test}" : "")
        proxies: []
        proxy-groups:
          - {name: Auto, type: url-test, proxies: []\(anchors ? ", <<: *shared" : "")}
        rules:
          - MATCH,Auto
        """
        #expect { try RuntimeConfig.build(profile: profile, settings: RuntimeSettings(), controllerPort: 0, secret: "test") } throws: {
            ($0 as? EditorError)?.message.contains("Auto”没有节点或 Provider") == true
        }
    }
}
