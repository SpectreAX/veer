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

    public func enable(host: String, port: Int, bypass: [String] = SystemProxy.defaultBypass) throws {
        let services = try services()
        guard !services.isEmpty else { throw EditorError("没有可用的网络服务，无法设置系统代理。") }
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
        var fields: [String: String] = [:]
        for line in try run(["-getwebproxy", service]).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields["Enabled"] == "Yes" && fields["Server"] == host && fields["Port"] == String(port)
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
            throw EditorError("无法设置系统代理：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
