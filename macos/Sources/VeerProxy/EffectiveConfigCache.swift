import CryptoKit
import Foundation

/// Keeps each profile's effective config (the profile with "my routing" applied) on disk, so the
/// first start after Veer opens does not replay the saved edits again: with seven edits on a
/// profile of nine thousand rules that took 0.9 s, every launch.
///
/// A kept result is used only when nothing it was made from has changed: the profile's text, the
/// layer's file, and the code that applied one to the other. Each is in the key, so there is no
/// separate step that could forget to throw a result away. A profile without a layer is not kept:
/// there is nothing to replay.
public struct EffectiveConfigCache: Sendable {
    let folder: URL
    /// Stands for the code that builds the result: a new build must not trust an older one's work.
    let stamp: String

    public init(paths: VeerPaths, stamp: String = EffectiveConfigCache.buildStamp) {
        folder = paths.effectiveCache
        self.stamp = stamp
    }

    /// The running program's size and date, which change with every build and update.
    public static let buildStamp: String = {
        let attributes = Bundle.main.executableURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(formatVersion)-\(size)-\(date)"
    }()

    /// Raised when what is stored, or what it means, changes.
    static let formatVersion = 2

    private struct Entry: Codable {
        let key: String
        let config: EffectiveConfig
    }

    /// The profile with its layer applied: the kept result when it still holds, else built now
    /// and kept. A failure to read or write the cache only costs the time to build.
    public func effective(of id: UUID, profiles: ProfileStore, routing: RoutingStore) throws -> EffectiveConfig {
        let text = try profiles.text(of: id)
        guard let (layer, data) = routing.loadWithData(id) else {
            remove(id)
            return try RoutingLayer().apply(to: text)
        }
        let key = Self.key(stamp: stamp, profile: text, layer: data)
        if let stored = try? Data(contentsOf: file(id)), let entry = try? JSONDecoder().decode(Entry.self, from: stored), entry.key == key {
            return entry.config
        }
        let config = try layer.apply(to: text)
        store(Entry(key: key, config: config), for: id)
        return config
    }

    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }

    /// Lengths go in with the parts, so no two different sets of parts read as the same bytes.
    static func key(stamp: String, profile: String, layer: Data) -> String {
        var hash = SHA256()
        for part in [Data(stamp.utf8), Data(profile.utf8), layer] {
            hash.update(data: Data("\(part.count):".utf8))
            hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The text holds servers and passwords, like the profile itself: readable only by the user.
    private func store(_ entry: Entry, for id: UUID) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: file(id), options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }
}
