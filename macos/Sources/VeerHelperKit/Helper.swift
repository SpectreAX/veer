import Foundation
import Security

/// What Veer and its privileged helper share: names, paths and the XPC protocol.
public enum HelperConstants {
    /// The launchd label and Mach service of the helper.
    public static let label = "com.yamax.veer.helper"
    public static let plistName = "com.yamax.veer.helper.plist"
    /// The only app the helper serves.
    public static let appIdentifier = "com.yamax.veer"
    /// Bumped when the protocol or behavior changes; Veer reinstalls a helper that reports another.
    public static let version = "2"
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
