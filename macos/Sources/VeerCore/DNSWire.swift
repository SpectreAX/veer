import Foundation
import Network

/// A record type the DNS tool can ask for. Each one listed here is parsed into readable text, not
/// shown as bytes.
public enum DNSRecordKind: String, Sendable, CaseIterable, Identifiable {
    case ipv4 = "A", ipv6 = "AAAA", cname = "CNAME", mx = "MX", ns = "NS", txt = "TXT", soa = "SOA", ptr = "PTR"
    case srv = "SRV", caa = "CAA", https = "HTTPS", svcb = "SVCB", ds = "DS", dnskey = "DNSKEY"

    public var id: String { rawValue }

    public var code: UInt16 {
        switch self {
        case .ipv4: 1
        case .ns: 2
        case .cname: 5
        case .soa: 6
        case .ptr: 12
        case .mx: 15
        case .txt: 16
        case .ipv6: 28
        case .srv: 33
        case .ds: 43
        case .dnskey: 48
        case .svcb: 64
        case .https: 65
        case .caa: 257
        }
    }
}

/// How a query reaches a server. DNS over QUIC is not implemented.
public enum DNSTransport: String, Sendable, CaseIterable {
    case udp = "UDP", tcp = "TCP", tls = "DoT", https = "DoH"
}

/// A server the tool asks directly, and how.
public struct DNSEndpoint: Sendable, Hashable {
    public let transport: DNSTransport
    public let host: String
    public let port: UInt16
    /// The whole address for DNS over HTTPS.
    public let url: URL?

    public init(transport: DNSTransport, host: String, port: UInt16, url: URL? = nil) {
        self.transport = transport
        self.host = host
        self.port = port
        self.url = url
    }

    public var label: String {
        if let url { return url.absoluteString }
        let standard: UInt16 = transport == .tls ? 853 : 53
        let address = host.contains(":") ? "[\(host)]" : host
        return port == standard ? address : "\(address):\(port)"
    }

    /// `https://…/dns-query`, `tls://host[:853]`, `tcp://host[:53]`, `udp://host[:53]` or a bare
    /// `host[:port]`, which is asked over UDP. `quic://` and anything else is nil.
    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("https://") {
            guard let url = URL(string: value), let host = url.host(), !host.isEmpty else { return nil }
            self.init(transport: .https, host: host, port: UInt16(url.port ?? 443), url: url)
            return
        }
        var transport = DNSTransport.udp
        if let scheme = value.range(of: "://") {
            guard let named = ["udp": DNSTransport.udp, "tcp": .tcp, "tls": .tls][value[..<scheme.lowerBound].lowercased()] else { return nil }
            transport = named
            value = String(value[scheme.upperBound...])
        }
        guard let (host, port) = Self.hostAndPort(value, standard: transport == .tls ? 853 : 53) else { return nil }
        self.init(transport: transport, host: host, port: port)
    }

    /// `host`, `host:port` or `[v6]:port`.
    static func hostAndPort(_ value: String, standard: UInt16) -> (String, UInt16)? {
        var host = value, port = standard
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let parsed = UInt16(rest.dropFirst()) else { return nil }
                port = parsed
            }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            guard let parsed = UInt16(value[value.index(after: colon)...]) else { return nil }
            port = parsed
        }
        guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9.:-]+$"#, options: .regularExpression) != nil else { return nil }
        return (host, port)
    }
}

/// One record of a response, as text.
public struct DNSRecordRow: Sendable, Hashable, Identifiable {
    public enum Section: String, Sendable { case answer, authority, additional }

    public let section: Section
    public let name: String
    public let type: String
    public let ttl: Int
    public let data: String
    public let index: Int
    public var id: String { "\(section.rawValue)-\(index)" }

    /// The address, for A and AAAA records.
    public var address: IPAddr? { type == "A" || type == "AAAA" ? IPAddr(data) : nil }
}

/// A response as the server sent it.
public struct DNSResponse: Sendable, Hashable {
    public let id: UInt16
    /// NOERROR, NXDOMAIN, SERVFAIL…
    public let status: String
    /// The header's flags that are set, of qr aa tc rd ra ad cd.
    public let flags: [String]
    public let records: [DNSRecordRow]
    public let raw: [UInt8]

    public func records(in section: DNSRecordRow.Section) -> [DNSRecordRow] { records.filter { $0.section == section } }
    public var truncated: Bool { flags.contains("tc") }
    /// The resolver says it validated the answer (the AD flag). Nothing is validated here.
    public var resolverValidated: Bool { flags.contains("ad") }

    public var rawText: String {
        stride(from: 0, to: raw.count, by: 16).map { offset in
            raw[offset..<min(offset + 16, raw.count)].map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

/// DNS messages (RFC 1035, with EDNS from RFC 6891): building a query and reading every section of
/// a response.
public enum DNSWire {
    public static let statuses = ["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED", "YXDOMAIN", "YXRRSET", "NXRRSET", "NOTAUTH", "NOTZONE"]
    static let typeNames: [UInt16: String] = [
        1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX", 16: "TXT", 28: "AAAA", 33: "SRV", 35: "NAPTR", 41: "OPT", 43: "DS",
        46: "RRSIG", 47: "NSEC", 48: "DNSKEY", 50: "NSEC3", 64: "SVCB", 65: "HTTPS", 257: "CAA",
    ]

    /// The name to ask for: a domain as typed, in ASCII (Punycode for other scripts), or for an IP
    /// address its reverse name under in-addr.arpa or ip6.arpa.
    public static func queryName(_ text: String, type: DNSRecordKind) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let address = IPAddr(trimmed) {
            guard type == .ptr else { throw EditorError(String(localized: "IP 地址只能查 PTR 记录（反向解析）。")) }
            return reverseName(address)
        }
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw EditorError(String(localized: "请输入域名，例如 www.example.com。")) }
        return try trimmed.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            guard !label.isEmpty else { throw EditorError(String(localized: "域名里有空的一段。")) }
            let ascii = label.allSatisfy(\.isASCII) ? String(label) : "xn--" + (try punycode(String(label)))
            guard ascii.utf8.count < 64 else { throw EditorError(String(localized: "域名里有一段超过 63 个字符。")) }
            return ascii
        }.joined(separator: ".")
    }

    public static func reverseName(_ address: IPAddr) -> String {
        if address.isV4 {
            return address.description.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
        }
        let nibbles = (0..<32).map { index in String(UInt8(truncatingIfNeeded: (address.value >> (4 * index)).low32) & 0xf, radix: 16) }
        return nibbles.joined(separator: ".") + ".ip6.arpa"
    }

    /// RFC 3492, for one label.
    public static func punycode(_ label: String) throws -> String {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 128 }.map { Character(UnicodeScalar($0)!) }
        let basic = output.count
        var handled = basic, n = 128, delta = 0, bias = 72
        if basic > 0 { output.append("-") }
        func digit(_ value: Int) -> Character { Character(UnicodeScalar(UInt8(value < 26 ? 97 + value : 22 + value))) }
        while handled < input.count {
            guard let next = input.filter({ $0 >= n }).min() else { break }
            delta += (next - n) * (handled + 1)
            n = next
            for code in input {
                if code < n { delta += 1 }
                if code == n {
                    var quotient = delta, step = base
                    while true {
                        let threshold = step <= bias ? tMin : (step >= bias + tMax ? tMax : step - bias)
                        if quotient < threshold { break }
                        output.append(digit(threshold + (quotient - threshold) % (base - threshold)))
                        quotient = (quotient - threshold) / (base - threshold)
                        step += base
                    }
                    output.append(digit(quotient))
                    var adapted = handled == basic ? delta / damp : delta / 2
                    adapted += adapted / (handled + 1)
                    var steps = 0
                    while adapted > ((base - tMin) * tMax) / 2 {
                        adapted /= base - tMin
                        steps += base
                    }
                    bias = steps + (base - tMin + 1) * adapted / (adapted + skew)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// A query for `name` (already ASCII). With `dnssec` it carries an EDNS record with the DO bit:
    /// a request for signatures, not a validation.
    public static func query(_ name: String, type: DNSRecordKind, id: UInt16, dnssec: Bool) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes.append(0)
        bytes += [UInt8(type.code >> 8), UInt8(type.code & 0xff), 0, 1]
        // OPT: root name, type 41, a 1232-byte UDP size, no extended rcode, version 0, DO or not.
        bytes += [0, 0, 41, 0x04, 0xd0, 0, 0, dnssec ? 0x80 : 0, 0, 0, 0]
        return bytes
    }

    public static func parse(_ data: [UInt8]) throws -> DNSResponse {
        func fail() -> EditorError { EditorError(String(localized: "DNS 服务器返回了无法读取的响应。")) }
        guard data.count >= 12 else { throw fail() }
        func u16(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        let bits = u16(2)
        let names = [(0x8000, "qr"), (0x0400, "aa"), (0x0200, "tc"), (0x0100, "rd"), (0x0080, "ra"), (0x0020, "ad"), (0x0010, "cd")]
        let flags = names.filter { bits & $0.0 != 0 }.map(\.1)
        var rcode = bits & 0x0f
        let counts = [u16(6), u16(8), u16(10)]
        var position = 12

        func name(at start: Int) throws -> (String, Int) {
            var labels: [String] = [], index = start, end: Int?, jumps = 0
            while true {
                guard index < data.count else { throw fail() }
                let length = Int(data[index])
                if length == 0 { index += 1; break }
                if length & 0xc0 == 0xc0 {
                    guard index + 1 < data.count, jumps < 32 else { throw fail() }
                    if end == nil { end = index + 2 }
                    index = (length & 0x3f) << 8 | Int(data[index + 1])
                    jumps += 1
                    continue
                }
                guard index + 1 + length <= data.count else { throw fail() }
                labels.append(text(data[(index + 1)..<(index + 1 + length)]))
                index += 1 + length
            }
            return (labels.isEmpty ? "." : labels.joined(separator: "."), end ?? index)
        }

        for _ in 0..<u16(4) { position = try name(at: position).1 + 4 }
        var rows: [DNSRecordRow] = []
        let sections: [DNSRecordRow.Section] = [.answer, .authority, .additional]
        for (section, count) in zip(sections, counts) {
            for _ in 0..<count {
                let (owner, afterName) = try name(at: position)
                guard afterName + 10 <= data.count else { throw fail() }
                let type = UInt16(u16(afterName))
                let ttl = data[(afterName + 4)..<(afterName + 8)].reduce(0) { $0 << 8 | Int($1) }
                let length = u16(afterName + 8), rdata = afterName + 10
                guard rdata + length <= data.count else { throw fail() }
                position = rdata + length
                if type == 41 {
                    // EDNS: the upper bits of the response code ride in its TTL.
                    rcode |= (ttl >> 24) << 4
                    continue
                }
                let text = try record(type: type, at: rdata, length: length, data: data, name: name)
                rows.append(DNSRecordRow(section: section, name: owner, type: typeNames[type] ?? "TYPE\(type)", ttl: ttl, data: text, index: rows.count))
            }
        }
        let status = rcode < statuses.count ? statuses[rcode] : (rcode == 16 ? "BADVERS" : "RCODE \(rcode)")
        return DNSResponse(id: UInt16(u16(0)), status: status, flags: flags, records: rows, raw: data)
    }

    static func text(_ bytes: ArraySlice<UInt8>) -> String { String(bytes: bytes, encoding: .utf8) ?? hex(bytes) }
    static func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Length-prefixed strings, as in TXT records and ALPN lists.
    static func strings(_ slice: ArraySlice<UInt8>) -> [String] {
        var list: [String] = [], index = slice.startIndex
        while index < slice.endIndex {
            let next = min(index + 1 + Int(slice[index]), slice.endIndex)
            list.append(text(slice[(index + 1)..<next]))
            index = next
        }
        return list
    }

    private typealias NameReader = (Int) throws -> (String, Int)

    private static func record(type: UInt16, at start: Int, length: Int, data: [UInt8], name: NameReader) throws -> String {
        let bytes = data[start..<(start + length)]
        if let common = try commonRecord(type: type, at: start, bytes: bytes, data: data, name: name) { return common }
        if let other = try otherRecord(type: type, at: start, bytes: bytes, name: name) { return other }
        return length == 0 ? "" : "\\# \(length) \(hex(bytes))"
    }

    private static func number(_ bytes: ArraySlice<UInt8>, at offset: Int, count: Int = 2) -> Int {
        let from = bytes.startIndex + offset
        guard from + count <= bytes.endIndex else { return 0 }
        return bytes[from..<(from + count)].reduce(0) { $0 << 8 | Int($1) }
    }

    /// Addresses, names, mail exchangers, text and the start of authority.
    private static func commonRecord(type: UInt16, at start: Int, bytes: ArraySlice<UInt8>, data: [UInt8], name: NameReader) throws -> String? {
        switch type {
        case 1 where bytes.count == 4, 28 where bytes.count == 16:
            return IPAddr(bytes: Array(bytes)).description
        case 2, 5, 12:
            return try name(start).0
        case 15 where bytes.count >= 3:
            return "\(number(bytes, at: 0)) \(try name(start + 2).0)"
        case 16:
            return strings(bytes).map { "\"\($0)\"" }.joined(separator: " ")
        case 6:
            let (primary, afterPrimary) = try name(start)
            let (mailbox, afterMailbox) = try name(afterPrimary)
            guard afterMailbox + 20 <= bytes.endIndex else { return "\(primary) \(mailbox)" }
            let numbers = (0..<5).map { number(data[afterMailbox...], at: $0 * 4, count: 4) }
            return "\(primary) \(mailbox) " + numbers.map(String.init).joined(separator: " ")
        default:
            return nil
        }
    }

    /// Services, certificate authorities, service bindings and the DNSSEC records.
    private static func otherRecord(type: UInt16, at start: Int, bytes: ArraySlice<UInt8>, name: NameReader) throws -> String? {
        let first = bytes.startIndex
        switch type {
        case 33 where bytes.count >= 7:
            return "\(number(bytes, at: 0)) \(number(bytes, at: 2)) \(number(bytes, at: 4)) \(try name(start + 6).0)"
        case 257 where bytes.count >= 2:
            let tagEnd = first + 2 + Int(bytes[first + 1])
            guard tagEnd <= bytes.endIndex else { return hex(bytes) }
            return "\(bytes[first]) \(text(bytes[(first + 2)..<tagEnd])) \"\(text(bytes[tagEnd...]))\""
        case 64, 65:
            guard bytes.count >= 3 else { return nil }
            let (target, afterTarget) = try name(start + 2)
            return (["\(number(bytes, at: 0))", target] + serviceParameters(bytes[afterTarget...])).joined(separator: " ")
        case 43 where bytes.count >= 4:
            return "\(number(bytes, at: 0)) \(bytes[first + 2]) \(bytes[first + 3]) \(hex(bytes[(first + 4)...]))"
        case 48 where bytes.count >= 4:
            return "\(number(bytes, at: 0)) \(bytes[first + 2]) \(bytes[first + 3]) (\((bytes.count - 4) * 8)-bit key)"
        case 46 where bytes.count >= 18:
            let covered = typeNames[UInt16(number(bytes, at: 0))] ?? "TYPE\(number(bytes, at: 0))"
            let signer = try name(start + 18).0
            return "\(covered) alg \(bytes[first + 2]) labels \(bytes[first + 3]) keytag \(number(bytes, at: 16)) signer \(signer)"
        default:
            return nil
        }
    }

    /// The key=value parameters of an HTTPS or SVCB record (RFC 9460).
    static func serviceParameters(_ bytes: ArraySlice<UInt8>) -> [String] {
        var parts: [String] = [], index = bytes.startIndex
        func addresses(_ value: ArraySlice<UInt8>, size: Int) -> String {
            stride(from: value.startIndex, to: value.endIndex - size + 1, by: size)
                .map { IPAddr(bytes: Array(value[$0..<($0 + size)])).description }.joined(separator: ",")
        }
        while index + 4 <= bytes.endIndex {
            let key = Int(bytes[index]) << 8 | Int(bytes[index + 1]), size = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let value = bytes[(index + 4)..<min(index + 4 + size, bytes.endIndex)]
            switch key {
            case 1: parts.append("alpn=" + strings(value).joined(separator: ","))
            case 3 where size == 2: parts.append("port=\(number(value, at: 0))")
            case 4: parts.append("ipv4hint=" + addresses(value, size: 4))
            case 6: parts.append("ipv6hint=" + addresses(value, size: 16))
            case 5: parts.append("ech=(\(size) bytes)")
            default: parts.append("key\(key)=\(hex(value))")
            }
            index = value.endIndex
        }
        return parts
    }
}

/// What came back from one query, and how it was asked.
public struct DNSExchange: Sendable, Hashable {
    public let name: String
    public let type: DNSRecordKind
    public let server: String
    /// The transport the answer came over: TCP when a UDP answer was cut short and asked again.
    public let transport: DNSTransport
    public let duration: TimeInterval
    public let response: DNSResponse
}

/// Sends one query straight to one server over UDP, TCP, TLS or HTTPS. Nothing else is asked, and
/// there is no fallback to another server or transport, except TCP after a UDP answer marked
/// truncated, to the same server. DNS over HTTPS ignores the system proxy settings, so every
/// transport takes the same path: from this Mac to the server, through the tunnel only when TUN
/// mode has taken over all traffic.
public struct DNSClient: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) { self.timeout = timeout }

    public func query(_ text: String, type: DNSRecordKind, endpoint: DNSEndpoint, dnssec: Bool = false) async throws -> DNSExchange {
        let name = try DNSWire.queryName(text, type: type)
        let id = endpoint.transport == .https ? 0 : UInt16.random(in: 1...UInt16.max)
        let message = Data(DNSWire.query(name, type: type, id: id, dnssec: dnssec))
        let start = Date()
        var transport = endpoint.transport
        var reply: Data
        switch endpoint.transport {
        case .udp:
            reply = try await DNSResolver.udp(message, host: endpoint.host, port: endpoint.port, timeout: timeout)
            if (try? DNSWire.parse([UInt8](reply)))?.truncated == true {
                reply = try await Self.stream(message, host: endpoint.host, port: endpoint.port, tls: false, timeout: timeout)
                transport = .tcp
            }
        case .tcp:
            reply = try await Self.stream(message, host: endpoint.host, port: endpoint.port, tls: false, timeout: timeout)
        case .tls:
            reply = try await Self.stream(message, host: endpoint.host, port: endpoint.port, tls: true, timeout: timeout)
        case .https:
            guard let url = endpoint.url else { throw EditorError(String(localized: "DoH 地址无效。")) }
            reply = try await Self.https(message, url: url, timeout: timeout)
        }
        let response = try DNSWire.parse([UInt8](reply))
        guard response.id == id else { throw EditorError(String(localized: "DNS 服务器返回了无法读取的响应。")) }
        return DNSExchange(name: name, type: type, server: endpoint.label, transport: transport,
                           duration: Date().timeIntervalSince(start), response: response)
    }

    /// The addresses macOS itself resolves the name to, through `getaddrinfo`: no record types beyond
    /// A and AAAA, no TTL and no message, as the system gives none. NXDOMAIN when there are none.
    public static func system(_ text: String, type: DNSRecordKind) async throws -> SystemAnswer {
        guard type == .ipv4 || type == .ipv6 else {
            throw EditorError(String(localized: "系统 DNS 只返回地址（A 和 AAAA），其他记录请选择一个 DNS 服务器。"))
        }
        let name = try DNSWire.queryName(text, type: type)
        let (status, answers) = try await DNSResolver.system(name, type: type == .ipv6 ? .aaaa : .a)
        return SystemAnswer(name: name, status: status, addresses: answers.map(\.data))
    }

    public struct SystemAnswer: Sendable, Hashable {
        public let name: String
        public let status: String
        public let addresses: [String]
    }

    /// RFC 8484, POST. The session takes no proxy from the system.
    static func https(_ message: Data, url: URL, timeout: TimeInterval) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EditorError(String(localized: "DoH 服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。"))
        }
        return data
    }

    private static var silent: Error { EditorError(String(localized: "DNS 服务器没有回应。")) }

    /// TCP or TLS (RFC 7858): the message after its two-byte length, and the same back.
    static func stream(_ message: Data, host: String, port: UInt16, tls: Bool, timeout: TimeInterval) async throws -> Data {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw EditorError(String(localized: "端口无效。")) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: tls ? .tls : .tcp)
        let queue = DispatchQueue(label: "veer.dns-stream")
        let finish = Once<Result<Data, Error>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                finish.setHandler { result in
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let framed = Data([UInt8(message.count >> 8), UInt8(message.count & 0xff)]) + message
                        connection.send(content: framed, completion: .contentProcessed { error in
                            if let error { finish.fire(.failure(error)) }
                        })
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { header, _, _, error in
                            guard let header, header.count == 2 else { return finish.fire(.failure(error ?? Self.silent)) }
                            let length = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
                            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                                if let body, body.count == length { finish.fire(.success(body)) } else { finish.fire(.failure(error ?? Self.silent)) }
                            }
                        }
                    case .failed(let error), .waiting(let error): finish.fire(.failure(error))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish.fire(.failure(EditorError(String(localized: "DNS 服务器 \(timeout.formatted()) 秒内没有回应。"))))
                }
            }
        } onCancel: {
            finish.fire(.failure(CancellationError()))
        }
    }
}
