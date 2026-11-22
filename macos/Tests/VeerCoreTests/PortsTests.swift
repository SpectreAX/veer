import Foundation
import Testing
@testable import VeerCore

/// The ports the core is given: free when picked, and never ones the system hands out by itself.
struct PortsTests {
    /// The system's ephemeral range: where a socket that asks for any port gets one.
    static func ephemeralRange() throws -> ClosedRange<Int> {
        func value(_ name: String) throws -> Int {
            var result: Int32 = 0
            var size = MemoryLayout<Int32>.size
            try #require(sysctlbyname(name, &result, &size, nil, 0) == 0)
            return Int(result)
        }
        return try value("net.inet.ip.portrange.first")...value("net.inet.ip.portrange.last")
    }

    /// Found in the integration tests: a suite starting listeners on any port took the port another
    /// suite had just picked for its core (the kernel gives a just-released ephemeral port to the next
    /// socket), and that core then never listened. A picked port is outside that range, so nothing
    /// the system hands out can take it before the core binds it.
    @Test func aPickedPortIsOutsideTheEphemeralRangeAndFree() throws {
        let ephemeral = try Self.ephemeralRange()
        for _ in 0..<50 {
            let port = try #require(Ports.free())
            #expect(!ephemeral.contains(port), "\(port) is in the ephemeral range \(ephemeral)")
            #expect(Ports.reserved.contains(port))
            #expect(Ports.bindable(port))
        }
    }

    #if os(macOS)
    /// The short-lived core that counts rule sets picks its controller port the same way.
    @Test func theRuleSetCounterPicksOutsideTheEphemeralRange() throws {
        let ephemeral = try Self.ephemeralRange()
        for _ in 0..<20 {
            let port = try RuleSetCounter.freePort()
            #expect(!ephemeral.contains(port), "\(port) is in the ephemeral range \(ephemeral)")
            #expect(Ports.reserved.contains(port))
        }
    }
    #endif

    /// The one check of a Mihomo log for a port another program holds, shared by the app's start
    /// and the rule-set counter.
    @Test func onlyTheBindErrorForThatPortCounts() {
        let log = [
            #"level=info msg="Start initial compatible provider default""#,
            #"level=error msg="[Provider] served pull error: Get \"http://127.0.0.1:31377/list.txt\": EOF""#,
            #"level=error msg="External controller listen error: listen tcp 127.0.0.1:31377: bind: address already in use""#,
        ]
        #expect(Ports.listenFailed(on: 31377, in: log))
        #expect(!Ports.listenFailed(on: 1377, in: log))
        #expect(!Ports.listenFailed(on: 7890, in: log))
        // A provider error that merely names the port is not a conflict.
        #expect(!Ports.listenFailed(on: 31377, in: log.prefix(2)))
    }

    @Test func aPortInUseIsNotBindable() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        try #require(listening && listen(fd, 1) == 0)
        #expect(!Ports.bindable(Int(UInt16(bigEndian: address.sin_port))))
    }
}
