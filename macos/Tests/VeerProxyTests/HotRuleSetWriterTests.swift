import Foundation
import Testing
import VeerHelperKit
@testable import VeerProxy

struct HotRuleSetFilesTests {
    @Test func onlyVeersOwnNamesPass() {
        for name in ["veer-hot-1", "veer-hot-42", "veer-hot-9999"] { #expect(HotRuleSetFiles.isValidName(name)) }
        for name in ["veer-hot-", "veer-hot-12345", "veer-hot-1.yaml", "veer-hot-1/../x", "../veer-hot-1", "veer-hot-a", "other", ""] {
            #expect(!HotRuleSetFiles.isValidName(name))
        }
    }

    @Test func theHelperRefusesWhatCouldReachOutsideOrGrowLarge() throws {
        let files = try HotRuleSetFiles.decode(HotRuleSetFiles.encode(["veer-hot-1": "payload: []\n"]))
        #expect(files == ["veer-hot-1": Data("payload: []\n".utf8)])
        #expect(throws: HotRuleSetFilesError.self) { try HotRuleSetFiles.decode(HotRuleSetFiles.encode(["../../etc/x": ""])) }
        #expect(throws: HotRuleSetFilesError.self) {
            try HotRuleSetFiles.decode(HotRuleSetFiles.encode(["veer-hot-1": String(repeating: "a", count: (1 << 20) + 1)]))
        }
        let many = Dictionary(uniqueKeysWithValues: (1...513).map { ("veer-hot-\($0)", "") })
        #expect(throws: HotRuleSetFilesError.self) { try HotRuleSetFiles.decode(HotRuleSetFiles.encode(many)) }
        #expect(throws: HotRuleSetFilesError.self) { try HotRuleSetFiles.decode(Data("not a plist".utf8)) }
    }

    @Test func writingReplacesTheFolderAndKeepsFilesPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veer-hot-files-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try HotRuleSetFiles.write(["veer-hot-1": Data("old".utf8), "veer-hot-2": Data("two".utf8)], replacingAll: true, into: home)
        try HotRuleSetFiles.write(["veer-hot-1": Data("new".utf8)], replacingAll: false, into: home)
        let folder = home + "/veer-hot/"
        #expect(try String(contentsOfFile: folder + "veer-hot-1.yaml", encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: folder + "veer-hot-2.yaml"))
        let mode = try FileManager.default.attributesOfItem(atPath: folder + "veer-hot-1.yaml")[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try HotRuleSetFiles.write(["veer-hot-3": Data("three".utf8)], replacingAll: true, into: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["veer-hot-3.yaml"])
    }

    @Test func anOlderHelperStillCounts() {
        #expect(HelperConstants.compatibleVersions.contains(HelperConstants.version))
        #expect(HelperConstants.compatibleVersions.contains("2"))
    }
}

struct HotRuleSetWriterTests {
    private struct Failing: HotRuleSetWriter {
        func reset(_ sets: HotRuleSets) async throws { throw HotRuleSetFilesError("no") }
        func write(_ lines: [String], to set: HotRuleSets.RuleSet) async throws { throw HotRuleSetFilesError("no") }
    }

    @Test func theLocalWriterStartsOverAndWritesOneSet() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veer-hot-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(HotRuleSets.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: folder.appendingPathComponent("veer-hot-99.yaml"))
        let writer = LocalRuleSetWriter(home: home)
        let hot = try #require(await HotRuleSets.prepared(for: RuleTemplateTests.profile, writer: writer))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == hot.sets.map { "\($0.name).yaml" }.sorted())
        let set = try #require(hot.set(for: "DIRECT"))
        try await writer.write(["DOMAIN-SUFFIX,example.com"], to: set)
        #expect(try String(contentsOf: folder.appendingPathComponent("\(set.name).yaml"), encoding: .utf8)
            == "payload:\n  - 'DOMAIN-SUFFIX,example.com'\n")
    }

    @Test func aWriterThatFailsLeavesTheCoreWithoutHotSets() async {
        #expect(await HotRuleSets.prepared(for: RuleTemplateTests.profile, writer: Failing()) == nil)
    }
}
