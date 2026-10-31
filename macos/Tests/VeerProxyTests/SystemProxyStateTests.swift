import Testing
@testable import VeerProxy

@MainActor struct SystemProxyStateTests {
    /// Turning the proxy off while turning it on must wait: running them together could leave the
    /// Mac's proxy pointing at a core that has gone.
    @Test func laterWorkWaitsForEarlierWork() async {
        let work = SerialWork()
        var log: [String] = []
        work.add {
            log.append("on started")
            try? await Task.sleep(for: .milliseconds(20))
            log.append("on finished")
        }
        work.add { log.append("off") }
        await work.finish()
        #expect(log == ["on started", "on finished", "off"])
    }

    @Test func aRememberedProxyIsNotReportedAsBypassed() {
        func reach(running: Bool = true, tun: Bool = false, on: Bool = false, remembered: Bool = false) -> TrafficReach {
            TrafficReach(running: running, tunActive: tun, systemProxyOn: on, systemProxyRemembered: remembered)
        }
        #expect(reach(running: false, remembered: true) == .stopped(proxyOnStart: true))
        #expect(reach(running: false) == .stopped(proxyOnStart: false))
        #expect(reach(tun: true) == .tun)
        #expect(reach(tun: true, on: true) == .tun)
        #expect(reach(on: true, remembered: true) == .systemProxy)
        #expect(reach(remembered: true) == .systemProxyComing)
        #expect(reach() == .bypassed)
    }
}
