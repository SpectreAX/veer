import Foundation
import Testing
@testable import VeerMobile
import VeerMobileKit
import Yams

@MainActor
struct LoopbackRuntimeTests {
    @Test
    func hardeningRemovesEveryAlternativeListenerAndPreservesRouting() throws {
        let unsafe = """
        external-controller: 127.0.0.1:19090
        secret: test-only-secret
        mixed-port: 17890
        allow-lan: true
        bind-address: '*'
        listeners: [{name: public, type: mixed, listen: 0.0.0.0, port: 18080}]
        tunnels: ['0.0.0.0:15353,example.invalid:53,DIRECT']
        tun: {enable: true, auto-route: true, auto-detect-interface: true, stack: system}
        port: 18081
        socks-port: 18082
        redir-port: 18083
        tproxy-port: 18084
        external-controller-tls: 0.0.0.0:19443
        external-controller-unix: /tmp/veer-test.sock
        external-controller-pipe: veer-test
        external-controller-cors: {allow-origins: ['*']}
        external-ui: dashboard
        external-ui-url: https://example.invalid/ui.zip
        external-ui-name: test
        external-doh-server: /dns-query
        interface-name: en0
        routing-mark: 42
        iptables: {enable: true}
        ebpf: {auto-redir: true}
        auto-redirect: true
        dns:
          enable: true
          listen: 0.0.0.0:15353
          enhanced-mode: redir-host
          nameserver: [https://example.invalid/dns-query]
        proxies: []
        rules: ['MATCH,DIRECT']
        """
        let hardened = try LoopbackRuntime.harden(unsafe)
        let result = try #require(try Yams.load(yaml: hardened) as? [String: Any])
        let removed = [
            "listeners", "tunnels", "port", "socks-port", "redir-port", "tproxy-port",
            "external-controller-tls", "external-controller-unix", "external-controller-pipe",
            "external-controller-cors", "external-ui", "external-ui-url", "external-ui-name",
            "external-doh-server", "interface-name", "routing-mark", "iptables", "ebpf", "auto-redirect",
        ]
        for key in removed { #expect(result[key] == nil, "Unexpected runtime entry: \(key)") }
        #expect(result["allow-lan"] as? Bool == false)
        #expect(result["bind-address"] as? String == "127.0.0.1")
        #expect(result["external-controller"] as? String == "127.0.0.1:19090")
        #expect(result["mixed-port"] as? Int == 17890)
        #expect(result["secret"] as? String == "test-only-secret")
        let tun = try #require(result["tun"] as? [String: Any])
        #expect(Set(tun.keys) == ["enable"])
        #expect(tun["enable"] as? Bool == false)
        let dns = try #require(result["dns"] as? [String: Any])
        #expect(dns["listen"] == nil)
        #expect(dns["enable"] as? Bool == true)
        #expect(dns["enhanced-mode"] as? String == "redir-host")
        #expect(dns["nameserver"] as? [String] == ["https://example.invalid/dns-query"])
        #expect(result["rules"] as? [String] == ["MATCH,DIRECT"])
        #expect((result["proxies"] as? [Any])?.isEmpty == true)

        let again = try LoopbackRuntime.harden(hardened)
        #expect(again == hardened)
    }

    @Test(arguments: [
        "mixed-port: 17890",
        "external-controller: 0.0.0.0:19090",
        "external-controller: 192.0.2.1:19090",
        "external-controller: localhost:19090",
        "external-controller: '[::1]:19090'",
        "external-controller: ''",
        "external-controller: 19090",
    ])
    func requiresExplicitIPv4LoopbackController(_ yaml: String) {
        #expect(throws: ProxyCoreError.self) { try LoopbackRuntime.harden(yaml) }
    }

    @Test(arguments: ["", "[]", "scalar", "- list", "external-controller: ["])
    func rejectsNonMappingOrMalformedYAML(_ yaml: String) {
        #expect(throws: (any Error).self) { try LoopbackRuntime.harden(yaml) }
    }

    @Test
    func minimalLoopbackConfigDoesNotAcquireDNSOrOtherListeners() throws {
        let result = try #require(try Yams.load(yaml: LoopbackRuntime.harden("external-controller: 127.0.0.1:19090")) as? [String: Any])
        #expect(result["dns"] == nil)
        #expect(result["listeners"] == nil)
        #expect(result["tunnels"] == nil)
        #expect(result["mixed-port"] == nil)
        #expect(result["allow-lan"] as? Bool == false)
    }
}
