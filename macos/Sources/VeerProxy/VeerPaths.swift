import Foundation
import VeerCore
import VeerHelperKit

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
    /// Subscription links (they carry access tokens) and API keys, readable only by the user.
    /// Only ad-hoc signed builds keep using it: the others move it into the Keychain.
    public var secrets: URL { root.appendingPathComponent("secrets.json") }
    /// One "my routing" layer per profile.
    public var routing: URL { root.appendingPathComponent("routing", isDirectory: true) }
    /// Agent conversations, one JSON file each.
    public var threads: URL { root.appendingPathComponent("threads", isDirectory: true) }
    /// What was running when Veer last quit, and the proxy settings it replaced.
    public var state: URL { root.appendingPathComponent("state.json") }

    /// A Team ID keeps the signature stable across rebuilds, so the Keychain does not ask again.
    /// Snapshots and temporary folders stay out of it: they would move the user's real secrets,
    /// since the app makes its store on launch even when it is only drawing snapshots.
    public func usesKeychain(team: String?, environment: [String: String]) -> Bool {
        team != nil && environment["VEER_SNAPSHOT_DIR"] == nil && root.standardizedFileURL == Self.defaultRoot.standardizedFileURL
    }

    public func makeSecretStore() -> KeyStoring {
        let file = FileKeyStore(url: secrets)
        guard usesKeychain(team: CodeSigning.teamIdentifier(), environment: ProcessInfo.processInfo.environment) else { return file }
        return MigratingKeyStore(store: KeychainKeyStore(), legacy: file)
    }

    public func prepare() throws {
        for directory in [root, profiles, core, routing] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
