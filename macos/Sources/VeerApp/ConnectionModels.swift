import Foundation
import VeerCore

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

    /// Through the proxy on `port`: ip.sb first, ipinfo.io when it fails.
    static func lookUp(throughPort port: Int) async -> ExitInfo? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: "127.0.0.1", kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: "127.0.0.1", kCFNetworkProxiesHTTPSPort: port,
        ] as [AnyHashable: Any]
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        func json(_ url: String) async -> [String: Any]? {
            guard let url = URL(string: url), let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let answer = await json("https://api.ip.sb/geoip"), let ip = answer["ip"] as? String {
            return ExitInfo(ip: ip, country: answer["country"] as? String, countryCode: answer["country_code"] as? String,
                            organization: (answer["organization"] as? String) ?? (answer["isp"] as? String))
        }
        if let answer = await json("https://ipinfo.io/json"), let ip = answer["ip"] as? String {
            let code = answer["country"] as? String
            return ExitInfo(ip: ip, country: code.flatMap { Locale.current.localizedString(forRegionCode: $0) }, countryCode: code,
                            organization: answer["org"] as? String)
        }
        return nil
    }

    /// The flag emoji for the country code.
    var flag: String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "" }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }
}
