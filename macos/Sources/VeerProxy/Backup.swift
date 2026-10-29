import Foundation
import VeerCore

/// A local backup: profiles, "my routing", Agent threads and Veer's settings in one zip. API
/// keys never go in; subscription links only when asked.
public enum Backup {
    /// What a backup holds, shown before restoring it.
    public struct Manifest: Codable, Sendable, Equatable {
        public var format = 1
        public var createdAt: Date
        public var appVersion: String
        public var profiles: [String]
        public var threads: Int
        public var hasSettings: Bool
        public var hasSubscriptionLinks: Bool
    }

    /// Veer's own preferences worth carrying over; window positions and Sparkle's state are not.
    public static let settingsKeys = [
        "runtimeSettings", "aiSettings", "searchSettings", "shareRuleLiterals", "restoreLastState", "showRateInMenuBar",
        "showExitIP", "reconnectAfterChanges", "collapsedGroups", "hotKeys", "activeProfile", "proxiesShowMap", "AppleLanguages",
    ]

    static let folder = "Veer Backup"

    /// Writes the zip to `destination`.
    public static func make(paths: VeerPaths, defaults: UserDefaults, profileStore: ProfileStore, includeLinks: Bool,
                            appVersion: String, to destination: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("veer-backup-\(UUID().uuidString)")
        let root = staging.appendingPathComponent(folder)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for item in [paths.profileIndex, paths.profiles, paths.routing, paths.threads] where manager.fileExists(atPath: item.path) {
            try manager.copyItem(at: item, to: root.appendingPathComponent(item.lastPathComponent))
        }
        let settings = settingsKeys.reduce(into: [String: Any]()) { result, key in
            if let value = defaults.object(forKey: key) { result[key] = value }
        }
        try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("settings.plist"))
        let profiles = profileStore.loadAll()
        if includeLinks {
            let links = profiles.reduce(into: [String: String]()) { result, profile in
                result[profile.id.uuidString] = profileStore.subscriptionURL(of: profile.id)?.absoluteString
            }
            try write(links, to: root.appendingPathComponent("subscriptions.json"))
        }
        let threads = (try? manager.contentsOfDirectory(atPath: paths.threads.path).filter { $0.hasSuffix(".json") }.count) ?? 0
        let manifest = Manifest(createdAt: .now, appVersion: appVersion, profiles: profiles.map(\.name), threads: threads,
                                hasSettings: !settings.isEmpty, hasSubscriptionLinks: includeLinks)
        try write(manifest, to: root.appendingPathComponent("manifest.json"))

        try? manager.removeItem(at: destination)
        try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path])
    }

    /// Opens a backup for a look: its manifest and where it was unpacked. Call `restore` with the
    /// folder, or remove it.
    public static func open(_ zip: URL) throws -> (manifest: Manifest, folder: URL) {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("veer-restore-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try ditto(["-x", "-k", zip.path, staging.path])
            let root = staging.appendingPathComponent(folder)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else {
                throw EditorError(String(localized: "这不是 Veer 的备份文件。"))
            }
            guard manifest.format <= 1 else { throw EditorError(String(localized: "这个备份来自更新的 Veer，请先升级。")) }
            return (manifest, root)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Replaces profiles, routing, threads and settings with the backup's. Subscription links
    /// come back only if the backup has them; links of profiles that are gone are removed.
    public static func restore(from root: URL, paths: VeerPaths, defaults: UserDefaults, profileStore: ProfileStore) throws {
        let manager = FileManager.default
        try paths.prepare()
        let oldIDs = profileStore.loadAll().map(\.id)
        for name in [paths.profileIndex, paths.profiles, paths.routing, paths.threads] {
            let source = root.appendingPathComponent(name.lastPathComponent)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.removeItem(at: name)
            try copyWithoutLinks(source, to: name)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.plist")),
           let settings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in settingsKeys {
                if let value = settings[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let restoredIDs = Set(profileStore.loadAll().map(\.id))
        for id in oldIDs where !restoredIDs.contains(id) { profileStore.forgetSubscriptionURL(of: id) }
        if let data = try? Data(contentsOf: root.appendingPathComponent("subscriptions.json")),
           let links = try? JSONDecoder().decode([String: String].self, from: data) {
            for (id, link) in links {
                guard let id = UUID(uuidString: id), restoredIDs.contains(id), let url = URL(string: link) else { continue }
                try profileStore.setSubscriptionURL(url, for: id)
            }
        }
        try? manager.removeItem(at: root.deletingLastPathComponent())
    }

    /// Copies regular files and folders only: a symbolic link in a backup could point anywhere.
    static func copyWithoutLinks(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let type = try manager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
        switch type {
        case .typeDirectory?:
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in try manager.contentsOfDirectory(atPath: source.path) {
                try copyWithoutLinks(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        case .typeRegular?:
            try manager.copyItem(at: source, to: destination)
        default:
            break
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    /// `/usr/bin/ditto`, which makes and opens the same zips Finder does.
    static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw EditorError(String(localized: "无法读写压缩文件：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
    }
}
