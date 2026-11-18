import Foundation
import Testing
@testable import VeerCore
@testable import VeerProxy

/// A kept effective config is used only while everything it was made from is unchanged.
@Suite struct EffectiveConfigCacheTests {
    struct Fixture {
        let paths: VeerPaths
        let profiles: ProfileStore
        let routing: RoutingStore
        let id = UUID()

        init() throws {
            paths = VeerPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("veer-effective-\(UUID().uuidString)"))
            try paths.prepare()
            profiles = ProfileStore(paths: paths)
            routing = RoutingStore(paths: paths)
            try profiles.save(Profile(id: id, name: "p", isSubscription: false, nodeCount: 3), text: RoutingLayerTests.profile)
        }

        func layer(_ prompt: String, domain: String) throws -> RoutingLayer {
            RoutingLayer(edits: [try RoutingLayerTests.edit(prompt, on: RoutingLayerTests.profile) {
                [.route(matchType: "DOMAIN-SUFFIX", match: domain, targetId: $0.target(named: "日本")!.id)]
            }])
        }

        var file: URL { paths.effectiveCache.appendingPathComponent("\(id.uuidString).json") }

        /// Marks the kept result, so a test can tell it from one built again.
        func markKept() throws {
            let text = try String(contentsOf: file, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "MATCH,节点选择", with: "MATCH,节点选择 # kept").utf8).write(to: file)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func theSameInputsGiveBackTheKeptResultWithItsReplay() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.routing.save(try fixture.layer("Netflix 走日本", domain: "netflix.com"), for: fixture.id)
        let cache = EffectiveConfigCache(paths: fixture.paths, stamp: "a")
        let built = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing)
        #expect(built.text.contains("DOMAIN-SUFFIX,netflix.com,日本") && built.replay?.appliedCount == 1)
        try fixture.markKept()
        let kept = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing)
        // The replay holds its own copy of the text, which the mark changed too.
        #expect(kept.text.contains("# kept") && kept.replay?.edits == built.replay?.edits)
    }

    @Test func aChangedProfileLayerOrBuildIsBuiltAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.routing.save(try fixture.layer("Netflix 走日本", domain: "netflix.com"), for: fixture.id)
        let cache = EffectiveConfigCache(paths: fixture.paths, stamp: "a")
        func fresh(_ cache: EffectiveConfigCache) throws -> String {
            let text = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing).text
            #expect(!text.contains("# kept"))
            try fixture.markKept()
            return text
        }
        _ = try fresh(cache)
        // Another build of Veer.
        _ = try fresh(EffectiveConfigCache(paths: fixture.paths, stamp: "b"))
        // The layer.
        try fixture.routing.save(try fixture.layer("YouTube 走日本", domain: "youtube.com"), for: fixture.id)
        #expect(try fresh(cache).contains("DOMAIN-SUFFIX,youtube.com,日本"))
        // The profile.
        let updated = RoutingLayerTests.profile.replacingOccurrences(of: "us1.example.invalid", with: "us9.example.invalid")
        try fixture.profiles.save(Profile(id: fixture.id, name: "p", isSubscription: false, nodeCount: 3), text: updated)
        #expect(try fresh(cache).contains("us9.example.invalid"))
    }

    @Test func aProfileWithoutALayerIsNotKeptAndAnOldResultGoes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let cache = EffectiveConfigCache(paths: fixture.paths, stamp: "a")
        try fixture.routing.save(try fixture.layer("Netflix 走日本", domain: "netflix.com"), for: fixture.id)
        _ = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        try fixture.routing.save(RoutingLayer(), for: fixture.id)
        let plain = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing)
        #expect(plain.text == RoutingLayerTests.profile && !FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func aDamagedFileOnlyCostsTheTimeToBuildAndOnlyTheUserCanReadIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.routing.save(try fixture.layer("Netflix 走日本", domain: "netflix.com"), for: fixture.id)
        let cache = EffectiveConfigCache(paths: fixture.paths, stamp: "a")
        _ = try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try Data("not json".utf8).write(to: fixture.file)
        #expect(try cache.effective(of: fixture.id, profiles: fixture.profiles, routing: fixture.routing).text.contains("netflix.com"))
    }

    @Test func partsOfTheKeyCannotRunIntoEachOther() {
        let one = EffectiveConfigCache.key(stamp: "a", profile: "bc", layer: Data("d".utf8))
        #expect(one != EffectiveConfigCache.key(stamp: "ab", profile: "c", layer: Data("d".utf8)))
        #expect(one != EffectiveConfigCache.key(stamp: "a", profile: "b", layer: Data("cd".utf8)))
        #expect(one == EffectiveConfigCache.key(stamp: "a", profile: "bc", layer: Data("d".utf8)))
    }
}
