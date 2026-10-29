import Foundation

/// Talks to the external controller of a running Mihomo core (the user's own: a local Mihomo,
/// Clash Verge, or a router on the LAN) to apply a draft and check what took effect.
///
/// A pushed payload never touches the core's config file, so reloading that file is always a
/// way back: `restore` reloads it, rules only or whole.
public struct MihomoController: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// How a draft reaches the core.
    public enum Mode: String, Sendable, CaseIterable {
        /// `PUT /rules`: only rules, sub-rules and rule providers; proxies, DNS, listeners and TUN
        /// keep running. Needs a core with that endpoint (MetaCubeX/mihomo#3373).
        case rules
        /// `PUT /configs`: the whole running config is replaced by the draft, including ports,
        /// DNS and TUN. Only right for a core that runs exactly this config.
        case config
    }

    /// A rule as the core reports it.
    public struct RunningRule: Sendable, Equatable, Decodable {
        public let type: String
        public let payload: String
        public let proxy: String
    }

    public let base: URL
    let secret: String?
    let transport: Transport

    public init(base: URL, secret: String?, transport: Transport? = nil) {
        self.base = base
        self.secret = secret?.isEmpty == true ? nil : secret
        self.transport = transport ?? Self.urlSession
    }

    /// The controller address as typed: HTTPS anywhere, HTTP only on this Mac or the local network
    /// (the draft carries node passwords). Credentials and queries are not allowed in it.
    public static func validate(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw EditorError(String(localized: "控制器地址无效，例如 127.0.0.1:9090 或 http://192.168.1.1:9090。"))
        }
        guard scheme == "https" || (scheme == "http" && SubscriptionFetcher.isLocalNetwork(host: host)) else {
            throw EditorError(String(localized: "配置包含节点密码：控制器地址必须是 HTTPS；HTTP 只能用于本机或局域网地址。"))
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw EditorError(String(localized: "控制器地址无效。")) }
        return url
    }

    // MARK: Reading

    public func version() async throws -> String {
        struct Version: Decodable { let version: String; let meta: Bool? }
        let version: Version = try await decode(request("GET", "/version"))
        return version.version
    }

    /// Whether the core has `PUT /rules`. Probed with a body that is not JSON: a core with the
    /// endpoint rejects it with 400 before doing anything; one without answers 404 or 405.
    public func supportsRuleUpdate() async throws -> Bool {
        let (_, response) = try await send(request("PUT", "/rules", body: Data("probe".utf8)))
        switch response.statusCode {
        case 400: return true
        case 404, 405: return false
        case 401, 403: throw EditorError(String(localized: "控制器拒绝了访问：密钥不正确。"))
        default: throw EditorError(String(localized: "控制器返回 HTTP \(response.statusCode)，无法判断是否支持只更新规则。"))
        }
    }

    /// Every policy name the core runs: groups, nodes and built-ins.
    public func proxyNames() async throws -> Set<String> {
        struct Proxies: Decodable { let proxies: [String: Ignored] }
        struct Ignored: Decodable {}
        let proxies: Proxies = try await decode(request("GET", "/proxies"))
        return Set(proxies.proxies.keys)
    }

    public func rules() async throws -> [RunningRule] {
        struct Rules: Decodable { let rules: [RunningRule] }
        let rules: Rules = try await decode(request("GET", "/rules"))
        return rules.rules
    }

    /// A rule set as the core reports it: entry count, and whether it has loaded at all.
    public struct RuleProviderState: Sendable, Equatable, Decodable {
        public let ruleCount: Int
        public let updatedAt: String?
        public let vehicleType: String?

        /// Go's zero time means the core never loaded the set.
        public var loaded: Bool { updatedAt.map { !$0.hasPrefix("0001-01-01") } ?? false }
    }

    public func ruleProviders() async throws -> [String: RuleProviderState] {
        struct Providers: Decodable { let providers: [String: RuleProviderState] }
        let providers: Providers = try await decode(request("GET", "/providers/rules"))
        return providers.providers
    }

    /// The core's open connections (`GET /connections`); closed ones are gone from it.
    public func closeAllConnections() async throws {
        try await expectNoContent(request("DELETE", "/connections"))
    }

    /// One line of the core's log.
    public struct LogLine: Sendable, Equatable, Decodable {
        /// debug, info, warning or error.
        public let type: String
        public let payload: String
    }

    /// The core's log from now on, at `level` and above, until cancelled or the core stops.
    public func logs(level: String) -> AsyncThrowingStream<LogLine, Error> {
        var stream = request("GET", "/logs", query: ["level": level])
        stream.timeoutInterval = 60 * 60 * 24
        let request = stream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw EditorError(String(localized: "控制器返回了无法识别的响应。"))
                    }
                    for try await line in bytes.lines {
                        if let entry = try? JSONDecoder().decode(LogLine.self, from: Data(line.utf8)) { continuation.yield(entry) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func closeConnection(_ id: String) async throws {
        try await expectNoContent(request("DELETE", "/connections/\(id)"))
    }

    public func connections() async throws -> [Connection] {
        struct Connections: Decodable { let connections: [Connection]? }
        let list: Connections = try await decode(request("GET", "/connections"))
        return list.connections ?? []
    }

    // MARK: Running a core (Veer)

    /// A policy as the core reports it: a group lists its members and the one it uses now.
    public struct Proxy: Sendable, Equatable, Decodable {
        public struct Delay: Sendable, Equatable, Decodable { public let delay: Int }
        public let name: String
        /// `Selector`, `URLTest`, `Fallback`, `LoadBalance`, `Relay`, or a node's protocol.
        public let type: String
        public let now: String?
        public let all: [String]?
        public let hidden: Bool?
        public let history: [Delay]?

        public init(name: String, type: String, now: String? = nil, all: [String]? = nil, hidden: Bool? = nil, history: [Delay]? = nil) {
            self.name = name
            self.type = type
            self.now = now
            self.all = all
            self.hidden = hidden
            self.history = history
        }

        public var isGroup: Bool { all != nil }
        /// Only a select group takes a choice from the user.
        public var isSelectable: Bool { type == "Selector" }
        /// The latest delay test, 0 when it failed; nil before any test.
        public var lastDelay: Int? { history?.last?.delay }
    }

    public func proxies() async throws -> [String: Proxy] {
        struct Proxies: Decodable { let proxies: [String: Proxy] }
        let proxies: Proxies = try await decode(request("GET", "/proxies"))
        return proxies.proxies
    }

    /// Picks `proxy` in the select group `group`.
    public func select(_ proxy: String, in group: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": proxy])
        try await expectNoContent(request("PUT", "/proxies/" + group, body: body))
    }

    /// Tests every member of `group`; members that fail are missing from the result.
    public func testDelay(group: String, url: String = Self.delayURL, timeout: Int = 5000) async throws -> [String: Int] {
        try await decode(request("GET", "/group/" + group + "/delay", query: ["url": url, "timeout": String(timeout)]))
    }

    public static let delayURL = "https://www.gstatic.com/generate_204"

    /// `rule`, `global` or `direct`.
    public func mode() async throws -> String {
        struct Configs: Decodable { let mode: String }
        let configs: Configs = try await decode(request("GET", "/configs"))
        return configs.mode
    }

    public func setMode(_ mode: String) async throws {
        try await expectNoContent(request("PATCH", "/configs", body: JSONSerialization.data(withJSONObject: ["mode": mode])))
    }

    /// Bytes sent and received since the core started; two reads a second apart give the rate.
    public func trafficTotals() async throws -> (upload: Int64, download: Int64) {
        let totals = try await trafficSnapshot()
        return (totals.upload, totals.download)
    }

    /// The totals and how many connections are open, from one read.
    public func trafficSnapshot() async throws -> (upload: Int64, download: Int64, connections: Int) {
        struct ID: Decodable { let id: String }
        struct Totals: Decodable { let uploadTotal: Int64; let downloadTotal: Int64; let connections: [ID]? }
        let totals: Totals = try await decode(request("GET", "/connections"))
        return (totals.uploadTotal, totals.downloadTotal, totals.connections?.count ?? 0)
    }

    // MARK: Writing

    public func apply(_ yaml: String, mode: Mode) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["payload": yaml])
        try await expectNoContent(request("PUT", mode == .rules ? "/rules" : "/configs", body: body))
    }

    /// Reloads the core's own config file (rules only, or whole), undoing what `apply` pushed.
    public func restore(mode: Mode) async throws {
        try await expectNoContent(request("PUT", mode == .rules ? "/rules" : "/configs", body: Data("{}".utf8)))
    }

    // MARK: Checking

    /// Rules of the draft whose policy the core does not run; `PUT /rules` would refuse them.
    public static func missingTargets(in draft: ConfigDocument, running names: Set<String>) -> [String] {
        var missing: [String] = []
        for rule in draft.rules {
            guard let parts = RuleParts.parse(rule), parts.type != "SUB-RULE", !names.contains(parts.target),
                  !missing.contains(parts.target) else { continue }
            missing.append(parts.target)
        }
        return missing
    }

    /// Whether the core runs the draft's rules: same count and, rule by rule, the same policy.
    /// Types and payloads are spelled differently by the core, so they are not compared.
    public static func matches(_ running: [RunningRule], draft: ConfigDocument) -> Bool {
        let expected = draft.rules.map { RuleParts.parse($0)?.target }
        return running.count == expected.count && zip(running, expected).allSatisfy { $0.proxy == $1 }
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var url = base.appendingPathComponent(String(path.dropFirst()))
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: method == "GET" ? 10 : 60)
        request.httpMethod = method
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(request) } catch let error as EditorError { throw error } catch {
            throw EditorError(String(localized: "无法连接到控制器 \(base.host ?? "")：内核没有运行、地址不对，或没有开启 external-controller。"))
        }
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await send(request)
        try check(response, data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw EditorError(String(localized: "控制器的回应无法识别，它可能不是 Mihomo。"))
        }
    }

    private func expectNoContent(_ request: URLRequest) async throws {
        let (data, response) = try await send(request)
        try check(response, data)
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw EditorError(String(localized: "控制器拒绝了访问：密钥不正确。"))
        default:
            struct Message: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message
            throw EditorError(String(localized: "内核拒绝了请求（HTTP \(response.statusCode)）") + (message.map { "：\($0)" } ?? "。"))
        }
    }

    private static let urlSession: Transport = { request in
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EditorError(String(localized: "控制器返回了无法识别的响应。")) }
        // GET /rules of a large config stays well under this; anything bigger is not a controller.
        guard data.count <= 8 * 1024 * 1024 else { throw EditorError(String(localized: "控制器的回应过大。")) }
        return (data, http)
    }
}
