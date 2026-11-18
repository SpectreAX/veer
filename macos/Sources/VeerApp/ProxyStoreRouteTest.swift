import Foundation
import VeerCore
import VeerProxy

/// A destination the route tester opens with.
struct RouteTestRequest: Equatable {
    let host: String
    let port: Int
    let network: RouteQuery.Network

    /// A connection's destination: its domain, or `address:port` when the core saw no domain.
    /// A domain has no port in the row, so it gets 443, where most of it goes.
    init(host: String, network: String) {
        self.network = network.uppercased() == "UDP" ? .udp : .tcp
        if let colon = host.lastIndex(of: ":"), let port = Int(host[host.index(after: colon)...]), (1...65535).contains(port),
           IPAddr(String(host[..<colon])) != nil {
            self.host = String(host[..<colon])
            self.port = port
        } else {
            self.host = host
            port = 443
        }
    }
}

extension ProxyStore {
    /// Opens the route tester on a connection's destination.
    func testRoute(_ row: ConnectionRow) {
        routeTestRequest = RouteTestRequest(host: row.host, network: row.network)
        page = .route
    }

    /// The rules and data the route tester checks against: the config built as the core runs it,
    /// with Veer's own leading rules, and the core's folder. The hot rule sets count only while the
    /// core runs; a new start writes them empty. `fallback`: Veer's own geodata, for data the
    /// core's folder lacks.
    func routeTestSource(fallback: GeoDataStore? = .shared) async throws -> RouteTestSource {
        guard let profile = activeProfile else { throw EditorError(String(localized: "先导入一个配置")) }
        let text = try await effectiveTextInBackground(of: profile.id)
        let settings = settings, hot = isRunning ? hotSets : nil, home = paths.core
        return try await Task.detached(priority: .userInitiated) {
            let yaml = try RuntimeConfig.build(profile: text, settings: settings, controllerPort: 0, secret: "", hot: hot)
            return await RouteTestSource.load(config: yaml, home: home, fallback: fallback)
        }.value
    }

    /// Where `target` leads now: the policy, then each group's current choice, down to a node.
    /// Just the policy while the core is not running.
    func exitChain(from target: String) -> [String] {
        var chain = [target], seen: Set = [target]
        while chain.count < 8, let group = groups.first(where: { $0.name == chain.last }), let now = group.now, seen.insert(now).inserted {
            chain.append(now)
        }
        return chain
    }
}
