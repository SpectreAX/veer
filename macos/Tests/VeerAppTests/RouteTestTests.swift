import Foundation
import Testing
@testable import VeerApp
import VeerCore

/// The route tester opens on a connection's destination, checks the sample profile's rules and
/// follows the policy to the node its groups have chosen.
@MainActor struct RouteTestTests {
    @Test func aConnectionsDestinationBecomesARequest() {
        let domain = RouteTestRequest(host: "www.example.com", network: "TCP")
        #expect(domain.host == "www.example.com" && domain.port == 443 && domain.network == .tcp)
        let address = RouteTestRequest(host: "1.2.3.4:53", network: "UDP")
        #expect(address.host == "1.2.3.4" && address.port == 53 && address.network == .udp)
        let v6 = RouteTestRequest(host: "2001:db8::1:8443", network: "tcp")
        #expect(v6.host == "2001:db8::1" && v6.port == 8443)
        // Not an address and a port: kept whole.
        #expect(RouteTestRequest(host: "example.com:abc", network: "TCP").host == "example.com:abc")
    }

    @Test func theExitFollowsEachGroupsChoiceToANode() {
        let store = SnapshotRunner.running()
        store.groups = [
            ProxyStore.Group(name: "Proxy", type: "Selector", now: "Auto", members: []),
            ProxyStore.Group(name: "Auto", type: "URLTest", now: "HK 01", members: []),
            ProxyStore.Group(name: "Loop", type: "Selector", now: "Loop", members: []),
        ]
        #expect(store.exitChain(from: "Proxy") == ["Proxy", "Auto", "HK 01"])
        #expect(store.exitChain(from: "DIRECT") == ["DIRECT"])
        #expect(store.exitChain(from: "Loop") == ["Loop"])
    }

    @Test func checksTheProfileTheCoreRuns() async throws {
        let store = SnapshotRunner.running(page: .route, config: SnapshotRunner.routeSampleConfig)
        let source = try await store.routeTestSource(fallback: nil)
        let trace = RouteTracer.trace(RouteQuery("api.github.com", port: 443, network: .tcp)!, rules: source.rules, data: source.data)
        #expect(trace.hit?.rule == "DOMAIN-SUFFIX,github.com,节点选择" && trace.certain)
        // The app rule cannot be decided from a destination, and the throwaway folder has no GeoSite
        // data, so a mainland site falls through to MATCH with both left open.
        let mainland = RouteTracer.trace(RouteQuery("www.bilibili.com", port: 443, network: .tcp)!, rules: source.rules, data: source.data)
        #expect(mainland.unknowns.map(\.outcome) == [.unknown(.connection("PROCESS-NAME")), .unknown(.geosite)])
        #expect(mainland.hit?.target == "节点选择" && !mainland.certain)
    }
}
