import Foundation
import VeerCore
import Yams

/// Regions for nodes whose names say nothing, from where their servers are: the server address
/// (resolved when it is a host name) looked up in the GeoIP database the core already keeps.
/// Offline apart from the DNS lookup the core makes anyway. A server is where traffic enters,
/// which for a relay is not where it leaves; so names and hand marks always win, and mainland
/// China, almost always a relay's entry, is never used.
public enum ServerRegions {
    /// Each proxy's server address, by name.
    public static func servers(in profile: String) -> [String: String] {
        guard let root = try? Yams.compose(yaml: profile), case .sequence(let proxies)? = root.mapping?[Node("proxies")] else { return [:] }
        var result: [String: String] = [:]
        for proxy in proxies {
            guard let name = proxy.mapping?[Node("name")]?.string, let server = proxy.mapping?[Node("server")]?.string,
                  !server.isEmpty else { continue }
            result[name] = server
        }
        return result
    }

    /// The core's GeoIP database in `home`: MetaCubeX's geoip.metadb, or a country.mmdb.
    public static func database(in home: URL) -> MaxMindDatabase? {
        for name in ["geoip.metadb", "Country.mmdb", "country.mmdb"] {
            if let data = try? Data(contentsOf: home.appendingPathComponent(name)), let db = try? MaxMindDatabase(data: data) { return db }
        }
        return nil
    }

    /// ISO codes by node name, for those of `names` whose server the database places in a region
    /// Veer knows. At most `limit` servers are looked up.
    public static func locate(_ names: [String], servers: [String: String], database: MaxMindDatabase, limit: Int = 64,
                              resolve: (String) -> [IPAddr] = resolve) -> [String: String] {
        var result: [String: String] = [:]
        for name in names.prefix(limit) {
            guard let server = servers[name] else { continue }
            let addresses = IPAddr(server).map { [$0] } ?? resolve(server)
            if let code = addresses.lazy.compactMap({ country(of: $0, in: database) }).first { result[name] = code }
        }
        return result
    }

    /// A two-letter country Veer can place, other than CN. MetaCubeX also labels some ranges
    /// with a provider ("GOOGLE", "CLOUDFLARE"); those say nothing about the place.
    static func country(of address: IPAddr, in database: MaxMindDatabase) -> String? {
        guard let (value, _) = try? database.lookup(address), let code = value["country"]?["iso_code"]?.string?.uppercased(),
              code.count == 2, code != "CN", NodeLocator.place(code) != nil else { return nil }
        return code
    }

    /// The host's addresses from the system resolver.
    public static func resolve(_ host: String) -> [IPAddr] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [IPAddr] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               let address = IPAddr(String(cString: buffer)) {
                result.append(address)
            }
            cursor = info.ai_next
        }
        return result
    }
}
