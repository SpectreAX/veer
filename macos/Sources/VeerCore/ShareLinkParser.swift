import Foundation

/// Ordered YAML value for generated configuration; rendered by `ConfigImporter`.
public indirect enum YAMLValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case list([YAMLValue])
    case map([(String, YAMLValue)])

    public static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.list(a), .list(b)): a == b
        case let (.map(a), .map(b)): a.map(\.0) == b.map(\.0) && zip(a, b).allSatisfy { $0.1 == $1.1 }
        default: false
        }
    }

    subscript(key: String) -> YAMLValue? {
        if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Converts V2Ray-style share links to Mihomo proxy entries.
///
/// Field mapping follows Mihomo's own converter (`common/convert` in the bundled mirror), so the
/// result matches what Mihomo itself produces for a link subscription. Differences: no random
/// User-Agent header is injected into ws-opts, `mierus`/`+realm` links are reported as
/// unsupported instead of converted, and fields Mihomo would reject at load time (an empty Hysteria
/// bandwidth, obfs without a password) are filled in or left out.
public enum ShareLinkParser {
    public struct Result: Sendable {
        public var proxies: [[(String, YAMLValue)]]
        /// Scheme → count of links that could not be converted.
        public var skipped: [String: Int]
    }

    public static func parse(_ text: String) -> Result {
        var result = Result(proxies: [], skipped: [:])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "://") else { continue }
            let scheme = line[..<range.lowerBound].lowercased()
            guard scheme.range(of: #"^[a-z0-9+]+$"#, options: .regularExpression) != nil else { continue }
            if let proxy = convert(line: line, scheme: scheme, body: String(line[range.upperBound...])) {
                result.proxies.append(proxy)
            } else {
                result.skipped[scheme, default: 0] += 1
            }
        }
        return result
    }

    // MARK: Link pieces

    struct Link {
        var user: String?
        var password: String?
        var host: String
        var port: String?
        var path: String
        var query: [String: String]
        var name: String
    }

    /// Splits `scheme://user:pass@host:port/path?query#name` without rejecting raw Unicode names.
    static func split(_ line: String) -> Link? {
        var rest = line
        var name = ""
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding ?? String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        guard let schemeEnd = rest.range(of: "://") else { return nil }
        rest = String(rest[schemeEnd.upperBound...])
        var query: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts[0].removingPercentEncoding ?? parts[0]
                // A literal "+" stays: share links percent-encode spaces, and "+" is common in paths and keys.
                let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                if query[key] == nil { query[key] = value }
            }
            rest = String(rest[..<mark])
        }
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = String(rest[..<slash])
        }
        var user: String?, password: String?
        if let at = rest.lastIndex(of: "@") {
            let info = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            // A stray "%" keeps the raw text instead of dropping the credential.
            if let colon = info.firstIndex(of: ":") {
                user = decoded(String(info[..<colon]))
                password = decoded(String(info[info.index(after: colon)...]))
            } else {
                user = decoded(info)
            }
        }
        var host = rest, port: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = String(after.dropFirst()) }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        }
        return Link(user: user, password: password, host: host, port: port, path: path, query: query, name: name)
    }

    static func decoded(_ raw: String) -> String { raw.removingPercentEncoding ?? raw }

    static func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    static func base64(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !s.isEmpty, s.range(of: #"^[A-Za-z0-9+/]+=*$"#, options: .regularExpression) != nil else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func base64String(_ text: String) -> String? { base64(text).flatMap { String(data: $0, encoding: .utf8) } }

    static func port(_ text: String?) -> YAMLValue? {
        guard let text, let value = Int(text), (1...65535).contains(value) else { return nil }
        return .int(value)
    }

    static func list(_ text: String?) -> YAMLValue? {
        guard let text, !text.isEmpty else { return nil }
        return .list(text.split(separator: ",").map { .string(String($0)) })
    }

    static func truthy(_ text: String?) -> Bool { ["1", "true", "yes"].contains(text?.lowercased() ?? "") }

    // MARK: Schemes

    static func convert(line: String, scheme: String, body: String) -> [(String, YAMLValue)]? {
        switch scheme {
        case "ss": return shadowsocks(line)
        case "ssr": return shadowsocksR(body)
        case "vmess": return vmess(line, body: body)
        case "vless": return vless(line)
        case "trojan": return trojan(line)
        case "hysteria": return hysteria(line)
        case "hysteria2", "hy2": return hysteria2(line)
        case "tuic": return tuic(line)
        case "socks", "socks5", "socks5h", "http", "https": return socks(line, scheme: scheme)
        case "anytls": return anytls(line)
        default: return nil
        }
    }

    static func shadowsocks(_ line: String) -> [(String, YAMLValue)]? {
        guard var link = split(line) else { return nil }
        if link.port == nil || link.user == nil {
            // Legacy form: ss://base64(method:password@host:port)#name
            let encoded = line.dropFirst(5).split(separator: "#").first.map(String.init) ?? ""
            let stem = encoded.split(separator: "?").first.map(String.init) ?? encoded
            guard let decoded = base64String(stem), let inner = split("ss://" + decoded) else { return nil }
            let name = link.name, query = link.query
            link = inner
            link.name = name
            link.query = query.merging(inner.query) { a, _ in a }
        }
        var cipher = link.user ?? "", password = link.password
        if password == nil {
            guard let decoded = base64String(cipher), let colon = decoded.firstIndex(of: ":") else { return nil }
            cipher = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
        }
        guard !link.host.isEmpty, let port = port(link.port), !cipher.isEmpty, let password else { return nil }
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("ss")), ("server", .string(link.host)), ("port", port),
                                            ("cipher", .string(cipher)), ("password", .string(password)), ("udp", .bool(true))]
        if link.query["udp-over-tcp"] == "true" || link.query["uot"] == "1" { proxy.append(("udp-over-tcp", .bool(true))) }
        if let plugin = link.query["plugin"], plugin.contains(";") { proxy += pluginOptions(plugin) }
        return proxy
    }

    /// SIP003 `plugin=name;key=value;flag` as Mihomo's obfs or v2ray-plugin.
    static func pluginOptions(_ plugin: String) -> [(String, YAMLValue)] {
        var info: [String: String] = [:]
        let parts = plugin.split(separator: ";").map(String.init)
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            info[pair[0]] = pair.count > 1 ? pair[1] : ""
        }
        let pluginName = parts[0]
        if pluginName.contains("obfs") {
            return [("plugin", .string("obfs")), ("plugin-opts", .map([("mode", .string(info["obfs"] ?? "")), ("host", .string(info["obfs-host"] ?? ""))]))]
        }
        guard pluginName.contains("v2ray-plugin") else { return [] }
        // TLS is the exact "tls" (or "tls=true") flag, not any "tls" inside a host or path.
        let tls = info["tls"].map { $0.isEmpty || truthy($0) } ?? false
        // v2ray-plugin's own default mode; Mihomo rejects an empty one.
        var opts: [(String, YAMLValue)] = [("mode", .string(nonEmpty(info["mode"]) ?? nonEmpty(info["obfs"]) ?? "websocket")),
                                           ("host", .string(info["host"] ?? info["obfs-host"] ?? "")),
                                           ("path", .string(info["path"] ?? "")), ("tls", .bool(tls))]
        if ["skip-cert-verify", "allowInsecure", "insecure"].contains(where: { truthy(info[$0]) }) { opts.append(("skip-cert-verify", .bool(true))) }
        return [("plugin", .string("v2ray-plugin")), ("plugin-opts", .map(opts))]
    }

    static func shadowsocksR(_ body: String) -> [(String, YAMLValue)]? {
        guard let decoded = base64String(body), let separator = decoded.range(of: "/?") else { return nil }
        let head = decoded[..<separator.lowerBound].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard head.count == 6, let port = port(head[1]) else { return nil }
        var query: [String: String] = [:]
        for pair in decoded[separator.upperBound...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { query[kv[0]] = base64String(kv[1]) ?? "" }
        }
        var proxy: [(String, YAMLValue)] = [("name", .string(query["remarks"] ?? "")), ("type", .string("ssr")), ("server", .string(head[0])), ("port", port),
                                            ("cipher", .string(head[3])), ("password", .string(base64String(head[5]) ?? "")),
                                            ("obfs", .string(head[4])), ("protocol", .string(head[2])), ("udp", .bool(true))]
        if let value = query["obfsparam"], !value.isEmpty { proxy.append(("obfs-param", .string(value))) }
        if let value = query["protoparam"], !value.isEmpty { proxy.append(("protocol-param", .string(value))) }
        return proxy
    }

    static func vmess(_ line: String, body: String) -> [(String, YAMLValue)]? {
        let payload = body.split(separator: "#").first.map(String.init) ?? body
        guard let data = base64(payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Xray VMessAEAD share link
            guard var proxy = vShare(line, type: "vmess") else { return nil }
            let link = split(line)
            proxy.append(("alterId", .int(0)))
            proxy.append(("cipher", .string(link?.query["encryption"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto")))
            return proxy
        }
        func text(_ key: String) -> String? {
            if let s = json[key] as? String { return s }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return nil
        }
        guard let name = json["ps"] as? String, let server = text("add"), let port = port(text("port")), let uuid = text("id") else { return nil }
        var proxy: [(String, YAMLValue)] = [("name", .string(name)), ("type", .string("vmess")), ("server", .string(server)), ("port", port),
                                            ("uuid", .string(uuid)), ("alterId", .int(Int(text("aid") ?? "0") ?? 0)), ("udp", .bool(true)),
                                            ("xudp", .bool(true))]
        let host = nonEmpty(text("host"))
        proxy += vmessSecurity(text, host: host)
        var network = (text("net") ?? "").lowercased()
        if text("type") == "http" { network = "http" } else if network == "http" { network = "h2" }
        // Mihomo has no "httpupgrade" network: it is ws with v2ray-http-upgrade, or the node runs raw TCP.
        if !network.isEmpty { proxy.append(("network", .string(network == "httpupgrade" ? "ws" : network))) }
        if proxy.contains(where: { $0.0 == "tls" && $0.1 == .bool(true) }), let alpn = list(text("alpn")) { proxy.append(("alpn", alpn)) }
        if let transport = vmessTransport(network, host: host, path: nonEmpty(text("path"))) { proxy.append(transport) }
        return proxy
    }

    /// TLS, certificate check, cipher, SNI and fingerprint of a `vmess://` JSON link.
    static func vmessSecurity(_ text: (String) -> String?, host: String?) -> [(String, YAMLValue)] {
        // "tls", "xtls", or a JSON true/1 (NSNumber reads as "1").
        let tlsText = (text("tls") ?? "").lowercased()
        let tls = tlsText.hasSuffix("tls") || tlsText == "1" || tlsText == "true"
        var pairs: [(String, YAMLValue)] = [("tls", .bool(tls)),
                                            ("skip-cert-verify", .bool(truthy(text("allowInsecure") ?? text("skip-cert-verify") ?? text("insecure")))),
                                            ("cipher", .string(nonEmpty(text("scy")) ?? "auto"))]
        if let sni = nonEmpty(text("sni")) {
            pairs.append(("servername", .string(sni)))
        } else if tls, let first = host?.split(separator: ",").first {
            // Without an SNI, clients send the Host header's name; the IP in "add" would fail the handshake.
            pairs.append(("servername", .string(String(first))))
        }
        if let fingerprint = nonEmpty(text("fp")) { pairs.append(("client-fingerprint", .string(fingerprint))) }
        return pairs
    }

    /// The `*-opts` entry for a `vmess://` JSON link's network, if it has one.
    static func vmessTransport(_ network: String, host: String?, path: String?) -> (String, YAMLValue)? {
        switch network {
        case "http":
            ("http-opts", .map([("path", .list([.string(path ?? "/")])), ("headers", .map(host.map { [("Host", .list([.string($0)]))] } ?? []))]))
        case "h2":
            ("h2-opts", .map([("path", .string(path ?? "/"))] + (host.map { [("host", .list([.string($0)]))] } ?? [])))
        case "ws", "httpupgrade":
            ("ws-opts", .map(wsOptions(path: path ?? "/", host: host, network: network)))
        case "grpc":
            ("grpc-opts", .map([("grpc-service-name", .string(path ?? ""))]))
        default:
            nil
        }
    }

    /// ws/httpupgrade options, moving `?ed=N` and `?eh=` from the path into early-data settings like
    /// Mihomo. For httpupgrade the caller writes `network: ws`; these options mark it as an upgrade.
    static func wsOptions(path: String, host: String?, network: String, earlyData: String? = nil, earlyHeader: String? = nil) -> [(String, YAMLValue)] {
        var opts: [(String, YAMLValue)] = []
        var cleanPath = path, early = earlyData, header = earlyHeader
        if var components = URLComponents(string: path), let items = components.queryItems {
            if let ed = items.first(where: { $0.name == "ed" })?.value { early = ed }
            if let eh = items.first(where: { $0.name == "eh" })?.value { header = eh }
            let rest = items.filter { $0.name != "ed" && $0.name != "eh" }
            components.queryItems = rest.isEmpty ? nil : rest
            cleanPath = components.string ?? path
        }
        opts.append(("path", .string(cleanPath)))
        opts.append(("headers", .map(host.map { [("Host", .string($0))] } ?? [])))
        if network == "httpupgrade" { opts.append(("v2ray-http-upgrade", .bool(true))) }
        if let early, let size = Int(early) {
            if network == "ws" {
                opts.append(("max-early-data", .int(size)))
                opts.append(("early-data-header-name", .string(header ?? "Sec-WebSocket-Protocol")))
            } else {
                opts.append(("v2ray-http-upgrade-fast-open", .bool(true)))
            }
        } else if let header {
            opts.append(("early-data-header-name", .string(header)))
        }
        return opts
    }

    /// Xray share-link standard shared by VLESS and VMessAEAD.
    static func vShare(_ line: String, type: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string(type)), ("server", .string(link.host)), ("port", port),
                                            ("uuid", .string(link.user ?? "")), ("udp", .bool(true))]
        proxy += vShareSecurity(q)
        if let key = q["pbk"], !key.isEmpty { proxy.append(("reality-opts", .map([("public-key", .string(key)), ("short-id", .string(q["sid"] ?? ""))]))) }
        switch q["packetEncoding"] {
        case "none": break
        case "packet": proxy.append(("packet-addr", .bool(true)))
        default: proxy.append(("xudp", .bool(true)))
        }
        guard let transport = vShareTransport(q) else { return nil }
        return proxy + transport
    }

    /// TLS, fingerprints, certificate check and SNI of an Xray share link.
    static func vShareSecurity(_ query: [String: String]) -> [(String, YAMLValue)] {
        let security = (query["security"] ?? "").lowercased()
        let tls = security.hasSuffix("tls") || security == "reality"
        var pairs: [(String, YAMLValue)] = []
        if tls {
            pairs.append(("tls", .bool(true)))
            pairs.append(("client-fingerprint", .string(nonEmpty(query["fp"]) ?? "chrome")))
            if let alpn = list(query["alpn"]) { pairs.append(("alpn", alpn)) }
            if let pcs = nonEmpty(query["pcs"]) { pairs.append(("fingerprint", .string(pcs))) }
            if truthy(query["allowInsecure"]) || truthy(query["insecure"]) { pairs.append(("skip-cert-verify", .bool(true))) }
        }
        if let sni = nonEmpty(query["sni"]) ?? nonEmpty(query["peer"]) {
            pairs.append(("servername", .string(sni)))
        } else if tls, let host = nonEmpty(query["host"]) {
            pairs.append(("servername", .string(host)))
        }
        return pairs
    }

    /// The share link's `type`, as Xray names it: tcp with an HTTP header is http, http is h2, and
    /// splithttp is xhttp's old name.
    static func vShareNetwork(_ query: [String: String]) -> String {
        let network = (query["type"] ?? "").lowercased()
        switch network {
        case "", "tcp": return query["headerType"]?.lowercased() == "http" ? "http" : "tcp"
        case "http": return "h2"
        case "splithttp": return "xhttp"
        default: return network
        }
    }

    /// `network` and its options for an Xray share link; nil for an early-data size that is not a number.
    static func vShareTransport(_ query: [String: String]) -> [(String, YAMLValue)]? {
        let network = vShareNetwork(query), host = nonEmpty(query["host"])
        // Mihomo has no "httpupgrade" network: it is ws with v2ray-http-upgrade, or the node runs raw TCP.
        var proxy: [(String, YAMLValue)] = [("network", .string(network == "httpupgrade" ? "ws" : network))]
        switch network {
        case "http":
            var opts: [(String, YAMLValue)] = [("path", .list([.string(query["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/")]))]
            if let method = query["method"], !method.isEmpty { opts.insert(("method", .string(method)), at: 0) }
            opts.append(("headers", .map(host.map { [("Host", .list([.string($0)]))] } ?? [])))
            proxy.append(("http-opts", .map(opts)))
        case "h2":
            var opts: [(String, YAMLValue)] = [("path", .string(query["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"))]
            if let host { opts.append(("host", .list([.string(host)]))) }
            proxy.append(("h2-opts", .map(opts)))
        case "ws", "httpupgrade":
            guard query["ed"].map({ Int($0) != nil }) ?? true else { return nil }
            let opts = wsOptions(path: query["path"] ?? "", host: host, network: network, earlyData: query["ed"], earlyHeader: query["eh"])
            proxy.append(("ws-opts", .map(opts)))
        case "grpc":
            proxy.append(("grpc-opts", .map([("grpc-service-name", .string(query["serviceName"] ?? ""))])))
        case "xhttp":
            proxy.append(("xhttp-opts", .map(["path", "host", "mode"].compactMap { key in nonEmpty(query[key]).map { (key, .string($0)) } })))
        default:
            break
        }
        return proxy
    }

    static func vless(_ line: String) -> [(String, YAMLValue)]? {
        guard var proxy = vShare(line, type: "vless") else { return nil }
        let q = split(line)?.query ?? [:]
        if let flow = q["flow"], !flow.isEmpty { proxy.append(("flow", .string(flow.lowercased()))) }
        if let encryption = q["encryption"], !encryption.isEmpty { proxy.append(("encryption", .string(encryption))) }
        return proxy
    }

    static func trojan(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port), let password = link.user else { return nil }
        let q = link.query
        let insecure = truthy(q["allowInsecure"]) || truthy(q["insecure"])
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("trojan")), ("server", .string(link.host)), ("port", port),
                                            ("password", .string(password)), ("udp", .bool(true)), ("skip-cert-verify", .bool(insecure))]
        if let sni = nonEmpty(q["sni"]) ?? nonEmpty(q["peer"]) { proxy.append(("sni", .string(sni))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        let network = (q["type"] ?? "").lowercased()
        // tcp, trojan-go's "original" and "none" are plain trojan: no network key.
        if !["", "tcp", "original", "none"].contains(network) { proxy.append(("network", .string(network == "httpupgrade" ? "ws" : network))) }
        if network == "ws" || network == "httpupgrade" {
            let opts = wsOptions(path: q["path"] ?? "/", host: nonEmpty(q["host"]), network: network, earlyData: q["ed"], earlyHeader: q["eh"])
            proxy.append(("ws-opts", .map(opts)))
        } else if network == "grpc" {
            proxy.append(("grpc-opts", .map([("grpc-service-name", .string(q["serviceName"] ?? ""))])))
        }
        proxy.append(("client-fingerprint", .string(q["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome")))
        if let pcs = q["pcs"], !pcs.isEmpty { proxy.append(("fingerprint", .string(pcs))) }
        return proxy
    }

    /// Used for a Hysteria v1 link without `up` or `down`, which Mihomo will not load.
    static let hysteriaDefaultBandwidth = "100 Mbps"

    static func hysteria(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("hysteria")), ("server", .string(link.host)), ("port", port)]
        if let sni = nonEmpty(q["peer"]) ?? nonEmpty(q["sni"]) { proxy.append(("sni", .string(sni))) }
        if let obfs = q["obfs"], !obfs.isEmpty { proxy.append(("obfs", .string(obfs))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let auth = q["auth"], !auth.isEmpty { proxy.append(("auth-str", .string(auth))) }
        if let proto = q["protocol"], !proto.isEmpty { proxy.append(("protocol", .string(proto))) }
        // Mihomo requires both and rejects an empty value; links often leave them out.
        proxy.append(("up", .string(nonEmpty(q["up"]) ?? nonEmpty(q["upmbps"]) ?? hysteriaDefaultBandwidth)))
        proxy.append(("down", .string(nonEmpty(q["down"]) ?? nonEmpty(q["downmbps"]) ?? hysteriaDefaultBandwidth)))
        proxy.append(("skip-cert-verify", .bool(truthy(q["insecure"]) || truthy(q["allowInsecure"]))))
        return proxy
    }

    /// Port hopping: host:443,20000-30000 → the line with port 443, and ports "443,20000-30000".
    static func hoppingPorts(_ line: String) -> (line: String, ports: String?) {
        guard let regex = try? NSRegularExpression(pattern: #"(@[^/?#]*?:)(\d+(?:[-,]\d+)+)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 2), in: line) else { return (line, nil) }
        let ports = String(line[range])
        let first = ports.split(whereSeparator: { $0 == "," || $0 == "-" }).first.map(String.init) ?? "443"
        return (line.replacingCharacters(in: range, with: first), ports)
    }

    static func hysteria2(_ line: String) -> [(String, YAMLValue)]? {
        let hop = hoppingPorts(line)
        var ports = hop.ports
        guard let link = split(hop.line), !link.host.isEmpty else { return nil }
        let q = link.query
        if ports == nil { ports = nonEmpty(q["mport"]) }
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("hysteria2")), ("server", .string(link.host)),
                                            ("port", port(link.port) ?? .int(443))]
        if let ports { proxy.append(("ports", .string(ports))) }
        var auth = link.user ?? ""
        if let pass = link.password { auth += ":" + pass }
        if !auth.isEmpty { proxy.append(("password", .string(auth))) }
        // Mihomo rejects obfs without a password, and "none" is no obfs at all.
        if let obfs = nonEmpty(q["obfs"]), obfs.lowercased() != "none", let obfsPassword = nonEmpty(q["obfs-password"]) {
            proxy.append(("obfs", .string(obfs)))
            proxy.append(("obfs-password", .string(obfsPassword)))
        }
        if let sni = nonEmpty(q["sni"]) { proxy.append(("sni", .string(sni))) }
        proxy.append(("skip-cert-verify", .bool(truthy(q["insecure"]) || truthy(q["allowInsecure"]))))
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let pin = nonEmpty(q["pinSHA256"]) { proxy.append(("fingerprint", .string(pin))) }
        if let up = nonEmpty(q["up"]) ?? nonEmpty(q["upmbps"]) { proxy.append(("up", .string(up))) }
        if let down = nonEmpty(q["down"]) ?? nonEmpty(q["downmbps"]) { proxy.append(("down", .string(down))) }
        return proxy
    }

    static func tuic(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port), let user = link.user else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("tuic")), ("server", .string(link.host)), ("port", port),
                                            ("udp", .bool(true))]
        if let password = link.password {
            proxy.append(("uuid", .string(user)))
            proxy.append(("password", .string(password)))
        } else {
            proxy.append(("token", .string(user)))
        }
        if let cc = q["congestion_control"], !cc.isEmpty { proxy.append(("congestion-controller", .string(cc))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let sni = q["sni"], !sni.isEmpty { proxy.append(("sni", .string(sni))) }
        if truthy(q["disable_sni"]) { proxy.append(("disable-sni", .bool(true))) }
        if truthy(q["allow_insecure"]) || truthy(q["insecure"]) || truthy(q["allowInsecure"]) { proxy.append(("skip-cert-verify", .bool(true))) }
        if let mode = q["udp_relay_mode"], !mode.isEmpty { proxy.append(("udp-relay-mode", .string(mode))) }
        return proxy
    }

    static func socks(_ line: String, scheme: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        var username = "", password = ""
        if let user = link.user {
            let raw = link.password.map { "\(user):\($0)" } ?? (base64String(user) ?? user)
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            username = parts.first ?? ""
            password = parts.count > 1 ? parts[1] : ""
        }
        let isHTTP = scheme == "http" || scheme == "https"
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name.isEmpty ? "\(link.host):\(link.port ?? "")" : link.name)),
                                            ("type", .string(isHTTP ? "http" : "socks5")), ("server", .string(link.host)), ("port", port),
                                            ("username", .string(username)), ("password", .string(password)), ("skip-cert-verify", .bool(true))]
        if scheme == "https" { proxy.append(("tls", .bool(true))) }
        return proxy
    }

    static func anytls(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        let username = link.user ?? ""
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name.isEmpty ? "\(link.host):\(link.port ?? "")" : link.name)), ("type", .string("anytls")),
                                            ("server", .string(link.host)), ("port", port), ("password", .string(link.password ?? username))]
        if let sni = nonEmpty(q["sni"]) { proxy.append(("sni", .string(sni))) }
        // hpkp is the certificate pin; fp is the TLS client fingerprint.
        if let pin = nonEmpty(q["hpkp"]) { proxy.append(("fingerprint", .string(pin))) }
        if let fingerprint = nonEmpty(q["fp"]) { proxy.append(("client-fingerprint", .string(fingerprint))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        proxy.append(("skip-cert-verify", .bool(truthy(q["insecure"]) || truthy(q["allowInsecure"]))))
        proxy.append(("udp", .bool(true)))
        return proxy
    }
}
