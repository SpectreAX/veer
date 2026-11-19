import Foundation

/// A MetaCubeX meta-rules-dat set a rule provider downloads, from its URL
/// (`…/geo/geosite/netflix.mrs` → geosite `netflix`).
public struct MetaCubeXSet: Sendable, Hashable {
    public let kind: String
    public let name: String

    public init?(url: String) {
        guard let components = URL(string: url)?.pathComponents, components.count >= 2 else { return nil }
        let kind = components[components.count - 2]
        guard kind == "geosite" || kind == "geoip" else { return nil }
        self.kind = kind
        name = (components.last! as NSString).deletingPathExtension
    }
}

/// Reading what someone typed as a destination, and naming services. Rules themselves are decided
/// by `RouteTracer`.
public enum RuleMatcher {
    public static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let parsed = url.host, host.contains("://") { host = parsed }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if IPAddress(host) != nil { return host }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if host.hasSuffix(".") { host.removeLast() }
        guard host.matches(#"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*[a-z0-9-]+$"#), host.count <= 253 else { return nil }
        return host
    }

    /// "netflix" for www.netflix.com or netflix.net; ignores numbering ("netflix-2") and case.
    static func namesService(_ name: String, in domain: String) -> Bool {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }.trimmingCharacters(in: .decimalDigits)
        guard key.count >= 3 else { return false }
        return domain.split(separator: ".").dropLast().contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == key }
    }
}

/// IPv4 or IPv6 address as bytes, for CIDR containment.
struct IPAddress: Hashable {
    let bytes: [UInt8]

    init?(_ text: String) {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    struct Network {
        let address: IPAddress
        let prefix: Int

        func contains(_ ip: IPAddress) -> Bool {
            guard ip.bytes.count == address.bytes.count else { return false }
            var remaining = prefix
            for (a, b) in zip(ip.bytes, address.bytes) {
                guard remaining > 0 else { return true }
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if a & mask != b & mask { return false }
                remaining -= bits
            }
            return true
        }
    }

    static func network(_ cidr: String) -> Network? {
        let parts = cidr.split(separator: "/")
        guard let address = IPAddress(String(parts[0])) else { return nil }
        let maxPrefix = address.bytes.count * 8
        let prefix = parts.count > 1 ? Int(parts[1]) ?? -1 : maxPrefix
        guard (0...maxPrefix).contains(prefix) else { return nil }
        return Network(address: address, prefix: prefix)
    }
}

/// One rule split into its parts, respecting parentheses in logical rules
/// (`AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT`) and keeping trailing flags apart.
public struct RuleParts: Sendable, Equatable {
    public let type: String
    /// nil for MATCH.
    public let payload: String?
    public let target: String
    /// Extra options after the target, such as `no-resolve` or `src`.
    public let flags: [String]

    public static func parse(_ line: String) -> RuleParts? {
        let parts = split(line)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let type = first.uppercased()
        if type == "MATCH" {
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            return RuleParts(type: type, payload: nil, target: parts[1], flags: Array(parts.dropFirst(2)))
        }
        guard parts.count > 2, !parts[2].isEmpty else { return nil }
        return RuleParts(type: type, payload: parts[1], target: parts[2], flags: Array(parts.dropFirst(3)))
    }

    /// The line's comma-separated parts, trimmed, with commas inside parentheses kept.
    static func split(_ line: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for char in line.trimmingCharacters(in: .whitespaces) {
            switch char {
            case "(": depth += 1; current.append(char)
            case ")": depth = max(0, depth - 1); current.append(char)
            case "," where depth == 0: parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(char)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }
}
