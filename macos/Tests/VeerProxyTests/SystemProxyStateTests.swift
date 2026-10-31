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

struct TUNApprovalTests {
    private func finished(from previous: HelperState?, to current: HelperState = .ready, tun: Bool = true,
                          active: Bool = false, running: Bool = true) -> Bool {
        current.finishesTUNSetup(from: previous, tunEnabled: tun, tunActive: active, running: running)
    }

    @Test func approvalTakesEffectOnce() {
        #expect(finished(from: .needsApproval))
        #expect(finished(from: .notInstalled))
        #expect(!finished(from: .ready), "a helper that was already ready and failed must not restart the core on every activation")
    }

    @Test func nothingElseRestartsTheCore() {
        #expect(!finished(from: nil))
        #expect(!finished(from: .needsApproval, to: .needsApproval))
        #expect(!finished(from: .needsApproval, tun: false))
        #expect(!finished(from: .needsApproval, active: true))
        #expect(!finished(from: .needsApproval, running: false))
    }
}
