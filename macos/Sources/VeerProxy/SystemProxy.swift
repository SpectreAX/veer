import Foundation
import VeerCore

/// The macOS system proxy, set per network service with `networksetup` (an admin user needs no
/// password for it). Veer only turns off a proxy that points at itself.
public struct SystemProxy: Sendable {
    /// Runs `networksetup` with these arguments and returns its output.
    public typealias Runner = @Sendable ([String]) throws -> String

    let run: Runner

    public init(runner: Runner? = nil) { run = runner ?? Self.networksetup }

    /// Bypassed by default: this Mac, the local network and captive-portal checks.
    public static let defaultBypass = ["127.0.0.1", "localhost", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "captive.apple.com"]

    /// Enabled network services (Wi-Fi, Ethernet …); disabled ones are listed with a `*`.
    public func services() throws -> [String] {
        try run(["-listallnetworkservices"]).split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// Points `names` (every enabled service when nil) at `host:port`.
    public func enable(host: String, port: Int, bypass: [String] = SystemProxy.defaultBypass, services names: [String]? = nil) throws {
        let services = try names ?? services()
        guard !services.isEmpty else { throw EditorError(String(localized: "没有可用的网络服务，无法设置系统代理。")) }
        for service in services {
            _ = try run(["-setwebproxy", service, host, String(port)])
            _ = try run(["-setsecurewebproxy", service, host, String(port)])
            _ = try run(["-setsocksfirewallproxy", service, host, String(port)])
            _ = try run(["-setproxybypassdomains", service] + bypass)
        }
    }

    /// Turns the proxy off on services where it points at `host:port`; another app's proxy stays.
    public func disable(host: String, port: Int) throws {
        for service in try services() where try pointsAt(service: service, host: host, port: port) {
            _ = try run(["-setwebproxystate", service, "off"])
            _ = try run(["-setsecurewebproxystate", service, "off"])
            _ = try run(["-setsocksfirewallproxystate", service, "off"])
        }
    }

    /// Whether any enabled service's web proxy is on and points at `host:port`.
    public func isEnabled(host: String, port: Int) throws -> Bool {
        try services().contains { try pointsAt(service: $0, host: host, port: port) }
    }

    private func pointsAt(service: String, host: String, port: Int) throws -> Bool {
        try endpoint(.web, of: service).pointsAt(host: host, port: port)
    }

    // MARK: Snapshots

    /// Records each service's three proxies and bypass list before Veer changes them.
    public func snapshot(services names: [String]? = nil) throws -> ProxySnapshot {
        try ProxySnapshot(services: (names ?? services()).map { name in
            ProxySnapshot.Service(name: name, web: try endpoint(.web, of: name), secure: try endpoint(.secure, of: name),
                                  socks: try endpoint(.socks, of: name), bypass: try bypassDomains(of: name))
        })
    }

    /// Puts back what `snapshot` recorded. A recorded proxy that pointed at `host:port` (left by a
    /// Veer that quit without cleaning up) comes back off; services the snapshot does not know
    /// only lose a proxy pointing at Veer.
    public func restore(_ snapshot: ProxySnapshot, host: String, port: Int) throws {
        let current = try services()
        for service in snapshot.services where current.contains(service.name) {
            for kind in ProxySnapshot.Kind.allCases {
                let saved = service[kind]
                if saved.enabled, !saved.server.isEmpty, saved.port > 0, !saved.pointsAt(host: host, port: port) {
                    _ = try run([kind.setter, service.name, saved.server, String(saved.port)])
                } else {
                    _ = try run([kind.stateSetter, service.name, "off"])
                }
            }
            // An empty argument leaves an empty list, as most Macs have; "Empty" would remove it.
            _ = try run(["-setproxybypassdomains", service.name] + (service.bypass.isEmpty ? [""] : service.bypass))
        }
        let known = Set(snapshot.services.map(\.name))
        for service in current where !known.contains(service) {
            guard try pointsAt(service: service, host: host, port: port) else { continue }
            for kind in ProxySnapshot.Kind.allCases { _ = try run([kind.stateSetter, service, "off"]) }
        }
    }

    func endpoint(_ kind: ProxySnapshot.Kind, of service: String) throws -> ProxySnapshot.Endpoint {
        var fields: [String: String] = [:]
        for line in try run([kind.getter, service]).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return ProxySnapshot.Endpoint(enabled: fields["Enabled"] == "Yes", server: fields["Server"] ?? "", port: Int(fields["Port"] ?? "") ?? 0)
    }

    /// `networksetup` answers "There aren't any bypass domains set on …" when the list is empty.
    func bypassDomains(of service: String) throws -> [String] {
        try run(["-getproxybypassdomains", service]).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren't any") }
    }

    public static let networksetup: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw EditorError(String(localized: "无法设置系统代理：\(text.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return text
    }
}

/// Each network service's proxy settings as they were before Veer set its own.
public struct ProxySnapshot: Codable, Sendable, Equatable {
    public enum Kind: CaseIterable, Sendable {
        case web, secure, socks

        var getter: String {
            switch self {
            case .web: "-getwebproxy"
            case .secure: "-getsecurewebproxy"
            case .socks: "-getsocksfirewallproxy"
            }
        }

        var setter: String {
            switch self {
            case .web: "-setwebproxy"
            case .secure: "-setsecurewebproxy"
            case .socks: "-setsocksfirewallproxy"
            }
        }

        var stateSetter: String { setter + "state" }
    }

    public struct Endpoint: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var server: String
        public var port: Int

        func pointsAt(host: String, port: Int) -> Bool { enabled && server == host && self.port == port }
    }

    public struct Service: Codable, Sendable, Equatable {
        public var name: String
        public var web: Endpoint
        public var secure: Endpoint
        public var socks: Endpoint
        public var bypass: [String]

        subscript(kind: Kind) -> Endpoint {
            switch kind {
            case .web: web
            case .secure: secure
            case .socks: socks
            }
        }
    }

    public var services: [Service]

    /// Adds services this snapshot does not have yet, such as one that appeared after a network change.
    public mutating func merge(_ other: ProxySnapshot) {
        let known = Set(services.map(\.name))
        services += other.services.filter { !known.contains($0.name) }
    }
}
