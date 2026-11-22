import Foundation

extension MihomoController {
    /// One connection as the core reports it: where it goes and how the core routed it.
    public struct Connection: Sendable, Equatable, Decodable {
        public struct Metadata: Sendable, Equatable, Decodable {
            public var network: String?
            public var host: String?
            public var destinationIP: String?
            public var destinationPort: String?
            public var process: String?
            /// The executable's full path as the kernel reports it; empty or missing when the core did
            /// not look the process up (`find-process-mode: off`, Global or Direct mode, its own traffic).
            public var processPath: String?

            public init(network: String? = nil, host: String? = nil, destinationIP: String? = nil, destinationPort: String? = nil, process: String? = nil,
                        processPath: String? = nil) {
                self.network = network
                self.host = host
                self.destinationIP = destinationIP
                self.destinationPort = destinationPort
                self.process = process
                self.processPath = processPath
            }
        }

        public let id: String
        public let metadata: Metadata
        /// The node first and the rule's policy last (`["JP-01", "日本出口"]`).
        public let chains: [String]
        /// The rule type as the core spells it (`RuleSet`, `DomainSuffix`, `Match`).
        public let rule: String
        public let rulePayload: String
        /// Bytes so far in each direction.
        public var upload: Int64 = 0
        public var download: Int64 = 0
        /// When the connection opened.
        public var start: Date?

        public init(id: String, metadata: Metadata, chains: [String], rule: String, rulePayload: String,
                    upload: Int64 = 0, download: Int64 = 0, start: Date? = nil) {
            self.id = id
            self.metadata = metadata
            self.chains = chains
            self.rule = rule
            self.rulePayload = rulePayload
            self.upload = upload
            self.download = download
            self.start = start
        }

        enum CodingKeys: String, CodingKey { case id, metadata, chains, rule, rulePayload, upload, download, start }

        /// The core writes times with fractional seconds and an offset (RFC 3339).
        static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            metadata = try container.decode(Metadata.self, forKey: .metadata)
            chains = try container.decodeIfPresent([String].self, forKey: .chains) ?? []
            rule = try container.decodeIfPresent(String.self, forKey: .rule) ?? ""
            rulePayload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
            upload = try container.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
            download = try container.decodeIfPresent(Int64.self, forKey: .download) ?? 0
            start = try container.decodeIfPresent(String.self, forKey: .start).flatMap(Self.date)
        }
    }
}

/// Where the core's connections went, one row per site (or address, when the core saw no domain),
/// gathered over successive reads so a connection that closed stays listed.
public struct RecentDestination: Sendable, Equatable, Identifiable {
    /// The domain, or the address when the connection had none.
    public let id: String
    public var isAddress: Bool
    public var port: String?
    public var process: String?
    /// The rule that routed the latest connection, in config spelling (`RULE-SET,netflix`).
    public var rule: String
    /// The rule's policy and, when it is a group, the node it chose.
    public var policy: String?
    public var node: String?
    public var connectionIDs: Set<String>
    /// Open in the latest read.
    public var active: Bool
    public var firstSeen: Date

    /// The start of an instruction for the composer: the site's domain without `www.`, or the
    /// address as a single-host range.
    public var instruction: String {
        if isAddress { return "\(id)/\(id.contains(":") ? 128 : 32) 走 " }
        let labels = id.split(separator: ".")
        return (id.hasPrefix("www.") && labels.count > 2 ? String(id.dropFirst(4)) : id) + " 走 "
    }
}

public enum RecentConnections {
    /// Folds one read of the core's connections into the rows so far, newest site first; a row
    /// keeps its place while the list refreshes. A site's route is the one of its latest
    /// connection, so a rule change shows on the next visit.
    public static func merge(_ rows: [RecentDestination], with connections: [MihomoController.Connection], at now: Date) -> [RecentDestination] {
        var byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for key in byID.keys { byID[key]?.active = false }
        for connection in connections {
            let host = connection.metadata.host?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let address = connection.metadata.destinationIP ?? ""
            let key = host.isEmpty ? address : host
            guard !key.isEmpty else { continue }
            let process = connection.metadata.process.flatMap { $0.isEmpty ? nil : $0 }
            var row = byID[key] ?? RecentDestination(id: key, isAddress: host.isEmpty, rule: "", connectionIDs: [], active: true, firstSeen: now)
            row.port = connection.metadata.destinationPort.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            row.process = process ?? row.process
            row.rule = ruleText(connection.rule, connection.rulePayload)
            row.policy = connection.chains.last
            row.node = connection.chains.count > 1 ? connection.chains.first : nil
            row.connectionIDs.insert(connection.id)
            row.active = true
            byID[key] = row
        }
        return byID.values.sorted { ($0.firstSeen, $1.id) > ($1.firstSeen, $0.id) }
    }

    /// The core's rule type in config spelling, with its payload: `RuleSet` + `netflix` → `RULE-SET,netflix`.
    public static func ruleText(_ type: String, _ payload: String) -> String {
        let spelled = ruleTypes[type] ?? type.uppercased()
        return payload.isEmpty ? spelled : "\(spelled),\(payload)"
    }

    private static let ruleTypes: [String: String] = [
        "Domain": "DOMAIN", "DomainSuffix": "DOMAIN-SUFFIX", "DomainKeyword": "DOMAIN-KEYWORD",
        "DomainRegex": "DOMAIN-REGEX", "DomainWildcard": "DOMAIN-WILDCARD", "GeoSite": "GEOSITE", "GeoIP": "GEOIP",
        "SrcGeoIP": "SRC-GEOIP", "IPASN": "IP-ASN", "SrcIPASN": "SRC-IP-ASN", "IPCIDR": "IP-CIDR",
        "SrcIPCIDR": "SRC-IP-CIDR", "IPSuffix": "IP-SUFFIX", "SrcIPSuffix": "SRC-IP-SUFFIX", "SrcPort": "SRC-PORT",
        "DstPort": "DST-PORT", "InPort": "IN-PORT", "InUser": "IN-USER", "InName": "IN-NAME", "InType": "IN-TYPE",
        "ProcessName": "PROCESS-NAME", "ProcessPath": "PROCESS-PATH", "ProcessNameRegex": "PROCESS-NAME-REGEX",
        "ProcessPathRegex": "PROCESS-PATH-REGEX", "RuleSet": "RULE-SET", "Network": "NETWORK", "Uid": "UID",
        "SubRules": "SUB-RULE", "Match": "MATCH", "AND": "AND", "OR": "OR", "NOT": "NOT",
    ]
}
