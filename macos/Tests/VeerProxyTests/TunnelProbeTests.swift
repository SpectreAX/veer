import Darwin
import Foundation
import Testing
@testable import VeerCore
@testable import VeerProxy

/// A stand-in for the core's proxy port: answers CONNECT, then closes at once (a core still
/// loading) or keeps the tunnel open (a core that runs).
private final class FakeProxy: @unchecked Sendable {
    enum Behaviour { case dropsAtOnce, keepsOpen, notAProxy }
    let port: Int
    private let listener: Int32

    init(_ behaviour: Behaviour) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
        }
        guard bound, listen(listener, 4) == 0 else { throw CocoaError(.fileReadUnknown) }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 512)
                _ = recv(client, &buffer, buffer.count, 0)
                let reply = Array((behaviour == .notAProxy ? "HTTP/1.1 404 Not Found\r\n\r\n" : "HTTP/1.1 200 Connection established\r\n\r\n").utf8)
                _ = send(client, reply, reply.count, 0)
                if behaviour == .keepsOpen { usleep(300_000) }
                close(client)
            }
        }
    }

    deinit { close(listener) }
}

@Suite struct TunnelProbeTests {
    @Test func aCoreStillLoadingDropsTheTunnelAtOnce() throws {
        let proxy = try FakeProxy(.dropsAtOnce)
        #expect(TunnelProbe.ask(proxyPort: proxy.port, controllerPort: 9) == .dropped)
    }

    @Test func aRunningCoreKeepsTheTunnelOpen() throws {
        let proxy = try FakeProxy(.keepsOpen)
        #expect(TunnelProbe.ask(proxyPort: proxy.port, controllerPort: 9) == .carried)
    }

    @Test func aPortThatIsNotAProxyOrNotOpenIsNeitherAnswer() throws {
        let proxy = try FakeProxy(.notAProxy)
        #expect(TunnelProbe.ask(proxyPort: proxy.port, controllerPort: 9) == .noProxy)
        let free = try #require(Ports.free())
        #expect(TunnelProbe.ask(proxyPort: free, controllerPort: 9) == .noProxy)
    }

    @Test func everyRuleSetAndNodeListHasToHaveLoadedButGroupsDoNotCount() {
        typealias Rules = MihomoController.RuleProviderState
        typealias Nodes = MihomoController.ProxyProviderState
        let never = "0001-01-01T00:00:00Z", loaded = "2026-11-16T22:14:09Z"
        let group = Nodes(updatedAt: never, vehicleType: "Compatible")
        #expect(MihomoController.allLoaded(rules: [:], nodes: ["G": group]))
        #expect(MihomoController.allLoaded(rules: ["hot": Rules(ruleCount: 0, updatedAt: loaded, vehicleType: "File")],
                                           nodes: ["G": group, "remote": Nodes(updatedAt: loaded, vehicleType: "HTTP")]))
        // The rule sets are read last: one not loaded yet means the core is not taking traffic.
        #expect(!MihomoController.allLoaded(rules: ["hot": Rules(ruleCount: 0, updatedAt: never, vehicleType: "File")], nodes: [:]))
        #expect(!MihomoController.allLoaded(rules: [:], nodes: ["remote": Nodes(updatedAt: never, vehicleType: "HTTP")]))
    }
}
