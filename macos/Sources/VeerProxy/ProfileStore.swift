import Foundation
import VeerCore

/// A config Veer can run: a local file or a subscription.
public struct Profile: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var isSubscription: Bool
    public var updatedAt: Date
    public var nodeCount: Int
    public var usage: SubscriptionUsage?

    public init(id: UUID = UUID(), name: String, isSubscription: Bool, updatedAt: Date = .now, nodeCount: Int, usage: SubscriptionUsage? = nil) {
        self.id = id
        self.name = name
        self.isSubscription = isSubscription
        self.updatedAt = updatedAt
        self.nodeCount = nodeCount
        self.usage = usage
    }
}

/// Profiles on disk: `profiles.json` lists them, `profiles/<id>.yaml` holds each config, and
/// subscription links live in the secrets file (0600), never in the index.
public final class ProfileStore: @unchecked Sendable {
    public let paths: VeerPaths
    let secrets: KeyStoring
    private let lock = NSLock()

    public init(paths: VeerPaths, secrets: KeyStoring? = nil) {
        self.paths = paths
        self.secrets = secrets ?? FileKeyStore(url: paths.secrets)
    }

    public func loadAll() -> [Profile] {
        lock.withLock {
            guard let data = try? Data(contentsOf: paths.profileIndex) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([Profile].self, from: data)) ?? []
        }
    }

    public func text(of id: UUID) throws -> String {
        do { return try String(contentsOf: file(id), encoding: .utf8) } catch {
            throw EditorError(String(localized: "找不到这个配置的文件，可能已被删除。"))
        }
    }

    /// Adds or replaces `profile` and its config text.
    public func save(_ profile: Profile, text: String) throws {
        try paths.prepare()
        try lock.withLock {
            try Data(text.utf8).write(to: file(profile.id), options: .atomic)
            var all = Self.read(paths.profileIndex)
            if let index = all.firstIndex(where: { $0.id == profile.id }) { all[index] = profile } else { all.append(profile) }
            try Self.write(all, to: paths.profileIndex)
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(id))
            try? Self.write(Self.read(paths.profileIndex).filter { $0.id != id }, to: paths.profileIndex)
        }
        secrets.delete(for: Self.secretKey(id))
    }

    public func subscriptionURL(of id: UUID) -> URL? { secrets.read(for: Self.secretKey(id)).flatMap(URL.init(string:)) }

    public func setSubscriptionURL(_ url: URL, for id: UUID) throws { try secrets.save(url.absoluteString, for: Self.secretKey(id)) }

    private func file(_ id: UUID) -> URL { paths.profiles.appendingPathComponent("\(id.uuidString).yaml") }

    static func secretKey(_ id: UUID) -> String { "subscription-\(id.uuidString)" }

    private static func read(_ url: URL) -> [Profile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    private static func write(_ profiles: [Profile], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }
}
