import Foundation
import Testing
@testable import VeerCore

struct MigratingKeyStoreTests {
    final class FakeKeys: KeyStoring, @unchecked Sendable {
        var keys: [String: String] = [:]
        var refused: Set<String> = []
        var garbled: Set<String> = []
        var reads = 0

        func read(for provider: String) -> String? {
            reads += 1
            return garbled.contains(provider) ? "garbled" : keys[provider]
        }

        func save(_ key: String, for provider: String) throws {
            if refused.contains(provider) { throw EditorError("refused") }
            keys[provider] = key
        }

        func delete(for provider: String) { keys[provider] = nil }
    }

    private func legacy(_ keys: [String: String]) throws -> FileKeyStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("secrets.json")
        let file = FileKeyStore(url: url)
        for (account, value) in keys { try file.save(value, for: account) }
        return file
    }

    private func exists(_ file: FileKeyStore) -> Bool { FileManager.default.fileExists(atPath: file.url.path) }

    @Test func everyEntryMovesAndTheFileGoes() throws {
        let file = try legacy(["deepSeek": "sk-one", "profile-a": "https://a.example/s?token=1"])
        let fake = FakeKeys()
        let store = MigratingKeyStore(store: fake, legacy: file)
        #expect(fake.keys == ["deepSeek": "sk-one", "profile-a": "https://a.example/s?token=1"])
        #expect(!exists(file))
        #expect(store.read(for: "deepSeek") == "sk-one")
    }

    @Test func aRefusedEntryStaysInTheFileAndStaysReadable() throws {
        let file = try legacy(["deepSeek": "sk-one", "profile-a": "link"])
        let fake = FakeKeys()
        fake.refused = ["profile-a"]
        let store = MigratingKeyStore(store: fake, legacy: file)
        #expect(file.all() == ["profile-a": "link"])
        #expect(fake.keys == ["deepSeek": "sk-one"])
        #expect(store.read(for: "profile-a") == "link")

        fake.refused = []
        _ = MigratingKeyStore(store: fake, legacy: file)
        #expect(fake.keys["profile-a"] == "link")
        #expect(!exists(file))
    }

    @Test func anEntryThatReadsBackDifferentlyStaysInTheFile() throws {
        let file = try legacy(["deepSeek": "sk-one"])
        let fake = FakeKeys()
        fake.garbled = ["deepSeek"]
        _ = MigratingKeyStore(store: fake, legacy: file)
        #expect(file.all() == ["deepSeek": "sk-one"])
    }

    @Test func theFileWinsOverAnOlderKeychainEntry() throws {
        let file = try legacy(["deepSeek": "sk-new"])
        let fake = FakeKeys()
        fake.keys = ["deepSeek": "sk-old"]
        _ = MigratingKeyStore(store: fake, legacy: file)
        #expect(fake.keys["deepSeek"] == "sk-new")
    }

    @Test func anUnreadableFileIsLeftAlone() throws {
        let file = try legacy([:])
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        _ = MigratingKeyStore(store: FakeKeys(), legacy: file)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "not json")
    }

    @Test func deletingDoesNotBringALeftoverBack() throws {
        let file = try legacy(["profile-a": "link"])
        let fake = FakeKeys()
        fake.refused = ["profile-a"]
        let store = MigratingKeyStore(store: fake, legacy: file)
        store.delete(for: "profile-a")
        #expect(store.read(for: "profile-a") == nil)
        #expect(file.read(for: "profile-a") == nil)
    }

    @Test func savingReplacesALeftover() throws {
        let file = try legacy(["profile-a": "old"])
        let fake = FakeKeys()
        fake.refused = ["profile-a"]
        let store = MigratingKeyStore(store: fake, legacy: file)
        fake.refused = []
        try store.save("new", for: "profile-a")
        #expect(store.read(for: "profile-a") == "new")
        #expect(fake.keys["profile-a"] == "new")
        #expect(file.read(for: "profile-a") == nil)
    }

    @Test func aFailedSaveKeepsTheOldValueAndReportsIt() throws {
        let fake = FakeKeys()
        let store = MigratingKeyStore(store: fake, legacy: try legacy([:]))
        try store.save("old", for: "deepSeek")
        fake.refused = ["deepSeek"]
        #expect(throws: EditorError.self) { try store.save("new", for: "deepSeek") }
        #expect(store.read(for: "deepSeek") == "old")
    }

    @Test func repeatedReadsAskTheStoreOnce() throws {
        let fake = FakeKeys()
        fake.keys = ["deepSeek": "sk-one"]
        let store = MigratingKeyStore(store: fake, legacy: try legacy([:]))
        for _ in 0..<5 {
            #expect(store.read(for: "deepSeek") == "sk-one")
            #expect(store.read(for: "missing") == nil)
        }
        #expect(fake.reads == 2)
    }
}

/// Uses the real login keychain, with its own service and made-up values, so only on request:
/// `VEER_KEYCHAIN_TEST=1 swift test --filter KeychainKeyStoreTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_KEYCHAIN_TEST"] != nil))
struct KeychainKeyStoreTests {
    @Test func savesReplacesAndDeletes() throws {
        let store = KeychainKeyStore(service: "com.yamax.veer.secrets.test.\(UUID().uuidString)")
        defer { store.delete(for: "account") }
        #expect(store.read(for: "account") == nil)
        try store.save("one", for: "account")
        #expect(store.read(for: "account") == "one")
        try store.save("二 two", for: "account")
        #expect(store.read(for: "account") == "二 two")
        #expect(KeychainKeyStore(service: "com.yamax.veer.secrets.test.\(UUID().uuidString)").read(for: "account") == nil)
        store.delete(for: "account")
        #expect(store.read(for: "account") == nil)
    }

    @Test func migratesAFileIntoTheKeychain() throws {
        let keychain = KeychainKeyStore(service: "com.yamax.veer.secrets.test.\(UUID().uuidString)")
        defer { keychain.delete(for: "account") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("secrets.json")
        let file = FileKeyStore(url: url)
        try file.save("value", for: "account")
        let store = MigratingKeyStore(store: keychain, legacy: file)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.read(for: "account") == "value")
        #expect(keychain.read(for: "account") == "value")
    }
}
