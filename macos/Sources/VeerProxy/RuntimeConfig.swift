import Foundation
import VeerCore
import Yams

/// What the user sets for the running core, on top of any profile.
public struct RuntimeSettings: Sendable, Equatable, Codable {
    /// One port for HTTP and SOCKS; the system proxy points here.
    public var mixedPort = 7890
    public var allowLAN = false
    public var logLevel = "info"

    public init(mixedPort: Int = 7890, allowLAN: Bool = false, logLevel: String = "info") {
        self.mixedPort = mixedPort
        self.allowLAN = allowLAN
        self.logLevel = logLevel
    }
}

/// The config Mihomo runs: the profile as it is, with Veer's ports and controller written over it.
public enum RuntimeConfig {
    /// Keys a profile may set that would open another way in, clash with Veer's port, or start
    /// TUN before Veer manages it.
    static let removed = [
        "port", "socks-port", "redir-port", "tproxy-port", "external-controller-tls", "external-controller-unix",
        "external-controller-pipe", "external-controller-cors", "external-ui", "external-ui-url", "external-ui-name", "tun",
    ]

    static let geodataMirrors: [(key: String, url: String)] = [
        ("geoip", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"),
        ("geosite", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"),
        ("mmdb", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"),
        ("asn", "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"),
    ]

    public static func build(profile: String, settings: RuntimeSettings, controllerPort: Int, secret: String) throws -> String {
        guard let root = try Yams.compose(yaml: profile), case .mapping(var mapping) = root else {
            throw EditorError(String(localized: "配置文件不是有效的 Mihomo 配置：顶层应该是键值对。"))
        }
        for key in removed { mapping[Node(key)] = nil }
        func set(_ key: String, _ value: Node) { mapping[Node(key)] = value }
        set("mixed-port", Node(String(settings.mixedPort), Tag(.int)))
        set("allow-lan", Node(settings.allowLAN ? "true" : "false", Tag(.bool)))
        set("log-level", Node(settings.logLevel))
        set("external-controller", Node("127.0.0.1:\(controllerPort)"))
        set("secret", Node(secret, Tag(.str), .doubleQuoted))
        // Keep the user's node choices and fake-IP mappings across restarts.
        set("profile", Node([(Node("store-selected"), Node("true", Tag(.bool))), (Node("store-fake-ip"), Node("true", Tag(.bool)))]))
        // A DNS listener is only for TUN or redirection, and port 53 needs root: without it the
        // core would fail to start as the user. The rest of `dns` (resolvers, fake-IP) applies.
        if case .mapping(var dns)? = mapping[Node("dns")] {
            dns[Node("listen")] = nil
            set("dns", .mapping(dns))
        }
        // Geodata is downloaded on the first start, before the proxy works; GitHub is often
        // unreachable then, so use the jsDelivr mirror unless the profile names its own.
        if mapping[Node("geox-url")] == nil {
            set("geox-url", Node(geodataMirrors.map { (Node($0.key), Node($0.url)) }))
        }
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }

    /// The config to export with Veer's overrides written in: what `build` makes, without the
    /// controller and secret, which only mean something to one run of the core.
    public static func export(profile: String, settings: RuntimeSettings) throws -> String {
        let built = try build(profile: profile, settings: settings, controllerPort: 0, secret: "")
        guard let root = try Yams.compose(yaml: built), case .mapping(var mapping) = root else { return built }
        mapping[Node("external-controller")] = nil
        mapping[Node("secret")] = nil
        return ConfigImporter.readableUnicode(try Yams.serialize(node: .mapping(mapping), allowUnicode: true))
    }

    /// A random controller secret for one run of the core.
    public static func makeSecret() -> String {
        (0..<32).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }
}
