import CryptoKit
import Foundation
import Testing
@testable import VeerEditor

private struct FixedKey: SessionKeyProvider {
    let value: SymmetricKey
    func key() throws -> SymmetricKey { value }
}

@Test func sessionsRoundTripEncryptedWithOwnerOnlyPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sessions.bin")
    let key = SymmetricKey(size: .bits256)
    let store = SessionStore(url: url, keyProvider: FixedKey(value: key))
    #expect(try store.load().isEmpty)
    let secret = "password: super-secret-node-credential"
    let session = StoredSession(id: UUID(), name: "veer.yaml", subtitle: "Netflix 走日本", hasUnexportedChanges: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), state: Data(secret.utf8))
    try store.save([session])
    let raw = try Data(contentsOf: url)
    #expect(raw.range(of: Data("super-secret".utf8)) == nil)
    #expect(raw.range(of: Data("veer.yaml".utf8)) == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(try store.load() == [session])
    let wrongKey = SessionStore(url: url, keyProvider: FixedKey(value: SymmetricKey(size: .bits256)))
    #expect(throws: EditorFailure.self) { try wrongKey.load() }
    let aside = try #require(try wrongKey.quarantine())
    #expect(FileManager.default.fileExists(atPath: aside.path))
    #expect(try wrongKey.load().isEmpty)
}

@Test func ruleMatcherFindsFirstHitAndReportsSkippedRules() throws {
    let rules = ["DOMAIN-SUFFIX,Netflix.com,香港 IPLC", "DOMAIN-KEYWORD,openai,美国", "GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve", "MATCH,PROXY"]
    let netflix = try #require(RuleMatcher.match(rules: rules, domain: "https://www.netflix.com/browse"))
    #expect(netflix.index == 1 && netflix.target == "香港 IPLC")
    #expect(try #require(RuleMatcher.match(rules: rules, domain: "api.openai.com")).target == "美国")
    let other = try #require(RuleMatcher.match(rules: rules, domain: "example.org"))
    #expect(other.rule == "MATCH,PROXY" && other.target == "PROXY" && other.index == 5)
    #expect(other.skipped == ["GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve"])
    #expect(RuleMatcher.match(rules: [], domain: "not a domain") == nil)
    #expect(try #require(RuleMatcher.match(rules: [], domain: "a.example.com")).rule == "MATCH,DIRECT")
}

@Test func previewDecodesOptionalPlanAndInspectRules() throws {
    let json = #"{"candidate":"rules: []\n","summaries":[],"warnings":[],"diff":[],"changed":false,"validation":{"status":"passed","message":"ok"},"plan":{"schemaVersion":1,"operations":[{"kind":"remove_rule","matchType":"DOMAIN-SUFFIX","match":"example.com"}]}}"#
    let preview = try JSONDecoder().decode(Preview.self, from: Data(json.utf8))
    #expect(preview.plan?.operations.first?.targetId == nil)
    let inspect = try JSONDecoder().decode(InspectResult.self, from: Data(#"{"count":1,"rules":["MATCH,DIRECT"]}"#.utf8))
    #expect(inspect.rules == ["MATCH,DIRECT"])
}
