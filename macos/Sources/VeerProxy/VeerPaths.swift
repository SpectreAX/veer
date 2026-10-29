import Foundation

/// Where Veer keeps its files: `~/Library/Application Support/Veer/`.
public struct VeerPaths: Sendable {
    public let root: URL

    public init(root: URL = VeerPaths.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Veer", isDirectory: true)
    }

    /// One YAML file per profile, plus `profiles.json` listing them.
    public var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var profileIndex: URL { root.appendingPathComponent("profiles.json") }
    /// Mihomo's home: geodata, its cache and the runtime config Veer writes.
    public var core: URL { root.appendingPathComponent("core", isDirectory: true) }
    public var runtimeConfig: URL { core.appendingPathComponent("runtime.yaml") }
    /// Subscription links (they carry access tokens), readable only by the user.
    public var secrets: URL { root.appendingPathComponent("secrets.json") }
    /// One "my routing" layer per profile.
    public var routing: URL { root.appendingPathComponent("routing", isDirectory: true) }
    /// Agent conversations, one JSON file each.
    public var threads: URL { root.appendingPathComponent("threads", isDirectory: true) }
    /// What was running when Veer last quit, and the proxy settings it replaced.
    public var state: URL { root.appendingPathComponent("state.json") }

    public func prepare() throws {
        for directory in [root, profiles, core, routing] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
