import Foundation
import Testing
@testable import VeerCore

/// Rule set entry counts from the bundled core. Needs `VEER_MIHOMO_BIN` and network access to
/// GitHub; the inline and local-file cases need neither, but share the setup.
struct RuleSetCounterTests {
    static let config = """
    proxies:
      - {name: JP, type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 日本, type: select, proxies: [JP]}
    rule-providers:
      netflix: {type: http, behavior: domain, format: mrs, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs", path: ./ruleset/netflix.mrs, interval: 86400, proxy: 日本}
      private-list: {type: http, behavior: classical, format: text, url: "http://127.0.0.1:9/list.txt", path: ./ruleset/list.txt, interval: 86400}
      mine: {type: inline, behavior: domain, payload: [a.example, b.example, c.example]}
      local: {type: file, behavior: domain, path: ./ruleset/local.yaml}
    rules:
      - RULE-SET,netflix,日本
      - MATCH,DIRECT
    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
    func countsComeFromTheCoreInEveryFormat() async throws {
        let counter = RuleSetCounter(binary: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]!))
        let counts = await counter.count(try ConfigDocument.parse(Self.config), timeout: 40)
        guard case .entries(let netflix) = counts["netflix"] else {
            Issue.record("netflix: \(String(describing: counts["netflix"]))")
            return
        }
        #expect(netflix > 10, "the netflix set lists dozens of domains")
        #expect(counts["mine"] == .entries(3))
        #expect(counts["local"] == .localFile)
        guard case .failed = counts["private-list"] else {
            Issue.record("an unreachable set must fail, got \(String(describing: counts["private-list"]))")
            return
        }
    }

    @Test func aConfigWithoutDownloadsNeedsNoCore() async throws {
        // A binary that does not exist: nothing here should try to start it.
        let counter = RuleSetCounter(binary: URL(fileURLWithPath: "/nonexistent/mihomo"))
        let text = Self.config.components(separatedBy: "\n").filter { !$0.contains("type: http") }.joined(separator: "\n")
            .replacingOccurrences(of: "  - RULE-SET,netflix,日本\n", with: "")
        let counts = await counter.count(try ConfigDocument.parse(text))
        #expect(counts == ["mine": .entries(3), "local": .localFile])
    }
}
