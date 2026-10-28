import Foundation
import Testing
@testable import VeerCore

/// Reading the core's connections and folding them into one row per site.
struct RecentConnectionsTests {
    /// `GET /connections` as Mihomo answers it (fields Veer does not read left in).
    static let body = """
    {"downloadTotal": 10, "uploadTotal": 5, "memory": 1, "connections": [
      {"id": "a", "metadata": {"network": "tcp", "type": "HTTP", "sourceIP": "127.0.0.1", "destinationIP": "198.18.0.7",
        "sourcePort": "50000", "destinationPort": "443", "host": "www.netflix.com", "dnsMode": "fake-ip",
        "process": "Safari", "processPath": "/Applications/Safari.app"},
       "upload": 1, "download": 2, "start": "2026-10-29T10:12:33.123456789+08:00",
       "chains": ["JP-01", "日本出口"], "rule": "RuleSet", "rulePayload": "netflix"},
      {"id": "b", "metadata": {"network": "udp", "type": "Tun", "destinationIP": "1.1.1.1", "destinationPort": "53", "host": ""},
       "chains": ["DIRECT"], "rule": "Match", "rulePayload": ""}
    ]}
    """

    @Test func connectionsAreReadFromTheController() async throws {
        let core = MihomoControllerTests.FakeCore()
        core.answers["GET /connections"] = (200, Self.body)
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: "s", transport: core.transport)
        let connections = try await controller.connections()
        #expect(connections.count == 2)
        #expect(connections[0].metadata.host == "www.netflix.com")
        #expect(connections[0].chains == ["JP-01", "日本出口"])
        #expect(connections[1].rule == "Match")
        // A core with no open connections answers null.
        core.answers["GET /connections"] = (200, #"{"connections": null}"#)
        #expect(try await controller.connections().isEmpty)
    }

    @Test func rowsShowTheRuleAndThePolicyItChose() async throws {
        let core = MihomoControllerTests.FakeCore()
        core.answers["GET /connections"] = (200, Self.body)
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:9090")!, secret: nil, transport: core.transport)
        let rows = RecentConnections.merge([], with: try await controller.connections(), at: Date(timeIntervalSince1970: 0))
        let netflix = try #require(rows.first { $0.id == "www.netflix.com" })
        #expect(netflix.rule == "RULE-SET,netflix")
        #expect(netflix.policy == "日本出口" && netflix.node == "JP-01")
        #expect(netflix.process == "Safari" && netflix.port == "443")
        #expect(netflix.instruction == "netflix.com 走 ")
        // No domain: the address stands for the site, and a rule for it is a single-host range.
        let address = try #require(rows.first { $0.id == "1.1.1.1" })
        #expect(address.isAddress && address.rule == "MATCH" && address.policy == "DIRECT" && address.node == nil)
        #expect(address.instruction == "1.1.1.1/32 走 ")
    }

    @Test func closedConnectionsStayAndTheLatestRouteWins() {
        func connection(_ id: String, _ host: String, _ chains: [String], _ rule: String = "DomainSuffix", _ payload: String = "example.com") -> MihomoController.Connection {
            .init(id: id, metadata: .init(host: host, destinationIP: "203.0.113.1"), chains: chains, rule: rule, rulePayload: payload)
        }
        var rows = RecentConnections.merge([], with: [connection("1", "a.example.com", ["DIRECT"]), connection("2", "b.example.com", ["DIRECT"])],
                                           at: Date(timeIntervalSince1970: 1))
        // b closes; a gets a new connection after the rules changed.
        rows = RecentConnections.merge(rows, with: [connection("3", "A.example.com", ["US-1", "美国"])], at: Date(timeIntervalSince1970: 2))
        #expect(rows.map(\.id) == ["a.example.com", "b.example.com"])
        #expect(rows[0].policy == "美国" && rows[0].active && rows[0].connectionIDs == ["1", "3"])
        #expect(rows[1].policy == "DIRECT" && !rows[1].active)
        // Rows keep their place; a new site goes on top.
        rows = RecentConnections.merge(rows, with: [connection("2", "b.example.com", ["DIRECT"]), connection("4", "c.example.com", ["DIRECT"])],
                                       at: Date(timeIntervalSince1970: 3))
        #expect(rows.map(\.id) == ["c.example.com", "a.example.com", "b.example.com"])
        #expect(RecentConnections.ruleText("IPCIDR6", "::1/128") == "IPCIDR6,::1/128")
        #expect(RecentConnections.ruleText("GeoSite", "youtube") == "GEOSITE,youtube")
    }

    @Test func ipv6AddressesGetASingleHostRange() {
        let rows = RecentConnections.merge([], with: [.init(id: "x", metadata: .init(destinationIP: "2001:db8::1"), chains: ["DIRECT"], rule: "Match", rulePayload: "")],
                                           at: Date())
        #expect(rows.first?.instruction == "2001:db8::1/128 走 ")
    }
}
