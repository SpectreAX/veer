import Foundation
import Security

/// What Veer and its privileged helper share: names, paths and the XPC protocol.
public enum HelperConstants {
    /// The launchd label and Mach service of the helper.
    public static let label = "com.yamax.veer.helper"
    public static let plistName = "com.yamax.veer.helper.plist"
    /// The only app the helper serves.
    public static let appIdentifier = "com.yamax.veer"
    /// Bumped when the protocol or behavior changes; Veer reinstalls a helper it is not compatible with.
    public static let version = "3"
    /// Helpers this Veer still works with. Version 2 cannot write hot rule sets, so under TUN each
    /// routing change reloads the config instead; asking to reinstall would turn TUN off meanwhile.
    public static let compatibleVersions: Set<String> = ["2", "3"]
    /// The root core's home: config, geodata cache and the copy of Mihomo it runs. Root only.
    public static let rootHome = "/Library/Application Support/Veer/core"
    /// Where a hand-installed helper lives (when SMAppService cannot register it).
    public static let installedHelper = "/Library/PrivilegedHelperTools/com.yamax.veer.helper"
    public static let installedCore = "/Library/PrivilegedHelperTools/com.yamax.veer.mihomo"
    public static let installedPlist = "/Library/LaunchDaemons/com.yamax.veer.helper.plist"
    /// Geodata files the root core can take from the user's core folder instead of downloading.
    public static let geodataFiles = ["geoip.dat", "geosite.dat", "country.mmdb", "GeoLite2-ASN.mmdb", "geoip.metadb", "ASN.mmdb"]
}

/// Calls Veer makes to the helper. Replies carry plain values so the interface needs no classes.
@objc public protocol VeerHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    /// Runs Mihomo as root with `config`; `geodata` is the user's core folder to copy geodata
    /// from. The reply is nil on success, or why it failed.
    func start(config: Data, geodata: String, reply: @escaping @Sendable (String?) -> Void)
    func stop(reply: @escaping @Sendable () -> Void)
    /// Whether the core runs, its last output lines, and its exit status when it stopped on its own.
    func status(reply: @escaping @Sendable (Bool, [String], Int32) -> Void)
    /// Writes hot rule set files into the root core's home (version 3 and later). `files` is a
    /// `HotRuleSetFiles` payload; with `replacingAll`, the sets already there are removed first.
    /// The reply is nil on success, or why it failed.
    func writeRuleSets(_ files: Data, replacingAll: Bool, reply: @escaping @Sendable (String?) -> Void)
}

/// Hot rule set files sent to the helper, which writes them where only root can: plain names and
/// small YAML texts, checked on the way in so a caller cannot reach outside the folder.
public enum HotRuleSetFiles {
    /// The folder in the core's home that holds them; config paths say `./veer-hot/<name>.yaml`.
    public static let folder = "veer-hot"
    static let maxFiles = 512
    static let maxBytes = 1 << 20

    public static func encode(_ files: [String: String]) throws -> Data {
        try PropertyListEncoder().encode(files)
    }

    /// The files by name, or why they are refused.
    public static func decode(_ data: Data) throws -> [String: Data] {
        guard let files = try? PropertyListDecoder().decode([String: String].self, from: data) else {
            throw HotRuleSetFilesError("规则集数据无法读取。")
        }
        guard files.count <= maxFiles else { throw HotRuleSetFilesError("规则集太多。") }
        return try files.reduce(into: [:]) { result, file in
            let bytes = Data(file.value.utf8)
            guard isValidName(file.key) else { throw HotRuleSetFilesError("规则集名称无效。") }
            guard bytes.count <= maxBytes else { throw HotRuleSetFilesError("规则集文件太大。") }
            result[file.key] = bytes
        }
    }

    /// `veer-hot-<number>`, the only names Veer gives them.
    public static func isValidName(_ name: String) -> Bool {
        let prefix = "veer-hot-", number = name.dropFirst(prefix.count)
        return name.hasPrefix(prefix) && (1...4).contains(number.count) && number.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Writes `files` as `<name>.yaml` into `home`'s folder for them, readable by the owner only.
    public static func write(_ files: [String: Data], replacingAll: Bool, into home: String) throws {
        let manager = FileManager.default
        let folder = home + "/" + Self.folder
        if replacingAll { try? manager.removeItem(atPath: folder) }
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, contents) in files where isValidName(name) {
            let url = URL(fileURLWithPath: folder + "/" + name + ".yaml")
            try contents.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

public struct HotRuleSetFilesError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Code signature checks shared by the app and the helper.
public enum CodeSigning {
    /// The Team ID of the code at `path`, or of the running process when nil.
    public static func teamIdentifier(path: String? = nil) -> String? {
        var code: SecStaticCode?
        if let path {
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess else { return nil }
        } else {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &code) == errSecSuccess else { return nil }
        }
        var info: CFDictionary?
        guard let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Signed by an Apple-issued certificate of `team`, optionally with a given identifier.
    public static func requirement(team: String, identifier: String? = nil) -> String {
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if let identifier { text += " and identifier \"\(identifier)\"" }
        return text
    }

    /// Whether the code at `path` is intact and meets `requirement`.
    public static func satisfies(path: String, requirement: String) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), compiled) == errSecSuccess
    }
}
