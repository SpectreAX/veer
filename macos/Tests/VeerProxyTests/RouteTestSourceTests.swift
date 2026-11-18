import Foundation
import Testing
import VeerCore
@testable import VeerProxy

/// The route tester reads the config's rules and the core's rule-set files, and only files inside
/// the core's folder.
struct RouteTestSourceTests {
    static func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("route-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sets"), withIntermediateDirectories: true)
        try "payload:\n  - DOMAIN-SUFFIX,classic.com\n  - IP-CIDR,9.9.9.0/24,no-resolve\n"
            .write(to: home.appendingPathComponent("sets/classic.yaml"), atomically: true, encoding: .utf8)
        try "# comment\n+.plus.com\n\nexact.com\n".write(to: home.appendingPathComponent("sets/domains.txt"), atomically: true, encoding: .utf8)
        try Data([0x4D, 0x52, 0x53, 0x01]).write(to: home.appendingPathComponent("sets/binary.mrs"))
        return home
    }

    static let config = """
    rules:
      - RULE-SET,classic,A
      - RULE-SET,domains,B
      - RULE-SET,inline,C
      - RULE-SET,netflix,D
      - RULE-SET,binary,E
      - RULE-SET,outside,F
      - MATCH,DIRECT
    rule-providers:
      classic: {type: file, behavior: classical, path: ./sets/classic.yaml, format: yaml}
      domains: {type: http, behavior: domain, path: ./sets/domains.txt, format: text, url: "https://example.com/domains.txt"}
      inline: {type: inline, behavior: domain, payload: ["inline.com"]}
      netflix: {type: http, behavior: domain, format: mrs, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs"}
      binary: {type: http, behavior: domain, format: mrs, path: ./sets/binary.mrs, url: "https://example.com/binary.mrs"}
      outside: {type: file, behavior: domain, path: ../../etc/hosts}
    """

    @Test func readsRuleSetsFromTheCoresFolder() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = await RouteTestSource.load(config: Self.config, home: home)
        #expect(source.rules.count == 7)
        #expect(source.data.ruleSets["classic"] == .classical(["DOMAIN-SUFFIX,classic.com", "IP-CIDR,9.9.9.0/24,no-resolve"]))
        #expect(source.data.ruleSets["domains"] == .domains(["+.plus.com", "exact.com"]))
        #expect(source.data.ruleSets["inline"] == .domains(["inline.com"]))
        #expect(source.data.ruleSets["netflix"] == .geosite("netflix"))
        // A binary MRS file, and a path that leaves the core's folder, are not read.
        #expect(Set(source.inputs.unreadable) == ["binary", "outside"])
        #expect(source.inputs.geosite == nil && source.inputs.geoip == nil)
        let trace = RouteTracer.trace(RouteQuery("www.plus.com", port: 443, network: .tcp)!, rules: source.rules, data: source.data)
        #expect(trace.hit?.target == "B")
    }

    @Test func aProviderWithoutAPathIsLookedForWhereMihomoDownloadsIt() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        // MD5 of the URL, in rules/.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("rules"), withIntermediateDirectories: true)
        let file = home.appendingPathComponent("rules/a9b9f04336ce0181a08e774e01113b31")
        try "a.com\n".write(to: file, atomically: true, encoding: .utf8)
        let found = RouteTestSource.file(path: nil, url: "http://example.com", home: home)
        #expect(found?.lastPathComponent == file.lastPathComponent)
        #expect(RouteTestSource.file(path: "/etc/hosts", url: nil, home: home) == nil)
    }
}
