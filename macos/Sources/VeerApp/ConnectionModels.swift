import Foundation
import VeerCore
import VeerProxy

/// One live connection as the connections page shows it.
struct ConnectionRow: Identifiable, Equatable {
    let id: String
    /// The domain, or the address and port when the core saw no domain.
    let host: String
    let process: String?
    let network: String
    /// The rule in config spelling: `RuleSet Github`, `Match`.
    let rule: String
    /// The policy first and the node last (`Proxy → Auto → HK 01`).
    let chain: [String]
    let upload: Int64
    let download: Int64
    let uploadRate: Int64
    let downloadRate: Int64
    let start: Date?

    init(_ connection: MihomoController.Connection, uploadRate: Int64, downloadRate: Int64) {
        id = connection.id
        let metadata = connection.metadata
        if let name = metadata.host, !name.isEmpty {
            host = name
        } else {
            host = [metadata.destinationIP, metadata.destinationPort].compactMap { $0 }.joined(separator: ":")
        }
        process = metadata.process.flatMap { $0.isEmpty ? nil : $0 }
        network = metadata.network ?? ""
        rule = connection.rulePayload.isEmpty ? connection.rule : "\(connection.rule) \(connection.rulePayload)"
        chain = connection.chains.reversed()
        upload = connection.upload
        download = connection.download
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
        start = connection.start
    }

    /// A connection known only from the core's log: too short for the poll to see. No byte counts.
    init(route: LogRoute, at time: Date) {
        id = "log-\(UUID().uuidString)"
        host = route.isAddress ? "\(route.host):\(route.port)" : route.host
        process = route.process
        network = route.network
        rule = route.rule
        chain = route.chain
        upload = 0
        download = 0
        uploadRate = 0
        downloadRate = 0
        start = time
    }

    /// The same app reaching the same host, to tell a polled connection from a logged one.
    var matchKey: String { "\(host)|\(process ?? "")" }

    /// The policy the rule chose (the first hop), where a filter by group looks.
    var policy: String { chain.first ?? "" }
    /// Whether the host is an address rather than a domain.
    var isAddress: Bool { address != nil }
    /// The host as an IP address, without its port.
    var address: IPAddr? {
        if let ip = IPAddr(host) { return ip }
        guard let colon = host.lastIndex(of: ":") else { return nil }
        return IPAddr(String(host[..<colon]))
    }
}

/// A connection that has closed, for the requests page.
struct ClosedRequest: Identifiable, Equatable {
    let row: ConnectionRow
    let closedAt: Date
    /// Seen only in the log, so it lasted under a second and its traffic is unknown.
    var fromLog = false
    var id: String { row.id }
}

/// One line of the core's log.
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let time = Date()
    /// debug, info, warning or error.
    let level: String
    let message: String
}

/// Where traffic leaves the proxy, as a public IP service sees it.
struct ExitInfo: Equatable {
    var ip: String
    var country: String?
    var countryCode: String?
    var organization: String?

    /// Neither service answered.
    static let unknown = ExitInfo(ip: "")

    /// Through the proxy on `port`. Several services are asked at once and the first answer
    /// wins: any one of them can be blocked, slow, or rate-limited on a given node.
    static func lookUp(throughPort port: Int) async -> ExitInfo? {
        let configuration = URLSessionConfiguration.ephemeral
        #if os(macOS)
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: "127.0.0.1", kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: "127.0.0.1", kCFNetworkProxiesHTTPSPort: port,
        ] as [AnyHashable: Any]
        #else
        // The iOS prototype compiles this file too. iOS has no constants for these keys; URLSession reads them by name.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ] as [AnyHashable: Any]
        #endif
        configuration.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: ExitInfo?.self) { group in
            for service in services {
                group.addTask {
                    guard let url = URL(string: service.url), let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return service.read(json)
                }
            }
            for await answer in group {
                if let answer, !answer.ip.isEmpty {
                    group.cancelAll()
                    return answer
                }
            }
            return nil
        }
    }

    /// Public services that report the caller's address, and how to read each one's answer.
    static let services: [(url: String, read: @Sendable ([String: Any]) -> ExitInfo?)] = [
        ("https://api.ip.sb/geoip", { json in
            (json["ip"] as? String).map { ExitInfo(ip: $0, country: json["country"] as? String, countryCode: json["country_code"] as? String,
                                                  organization: (json["organization"] as? String) ?? (json["isp"] as? String)) }
        }),
        ("https://ipwho.is/", { json in
            guard json["success"] as? Bool != false, let ip = json["ip"] as? String else { return nil }
            return ExitInfo(ip: ip, country: json["country"] as? String, countryCode: json["country_code"] as? String,
                            organization: (json["connection"] as? [String: Any])?["isp"] as? String)
        }),
        ("https://ipapi.co/json/", { json in
            (json["ip"] as? String).map { ExitInfo(ip: $0, country: json["country_name"] as? String, countryCode: json["country_code"] as? String,
                                                  organization: json["org"] as? String) }
        }),
        ("https://ipinfo.io/json", { json in
            guard let ip = json["ip"] as? String else { return nil }
            let code = json["country"] as? String
            return ExitInfo(ip: ip, country: code.flatMap { Locale.current.localizedString(forRegionCode: $0) }, countryCode: code,
                            organization: json["org"] as? String)
        }),
    ]

    /// The flag emoji for the country code.
    var flag: String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "" }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }
}
