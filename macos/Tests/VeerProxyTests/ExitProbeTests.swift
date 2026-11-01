import Testing
@testable import VeerProxy

struct ExitProbeTests {
    /// Time that moves only when the probe sleeps or a try takes it.
    private final class Clock: @unchecked Sendable {
        var now = Duration.zero
        var tries = 0
    }

    private func probe(_ clock: Clock, tryTakes: Duration = .zero, answerAt: Duration? = nil) async -> String? {
        await ExitProbe.run(timeout: .seconds(20), interval: .seconds(2), now: { clock.now }, sleep: { clock.now += $0 }, attempt: {
            clock.tries += 1
            clock.now += tryTakes
            if let answerAt, clock.now >= answerAt { return "1.2.3.4" }
            return nil
        })
    }

    @Test func aFirstAnswerEndsItAtOnce() async {
        let clock = Clock()
        #expect(await probe(clock, answerAt: .zero) == "1.2.3.4")
        #expect(clock.tries == 1)
        #expect(clock.now == .zero)
    }

    @Test func failuresBeforeTheTimeoutAreNotTheResult() async {
        let clock = Clock()
        #expect(await probe(clock, answerAt: .seconds(7)) == "1.2.3.4")
        #expect(clock.tries == 5)
    }

    @Test func givesUpOnlyOnceTheTimeoutHasPassed() async {
        let clock = Clock()
        #expect(await probe(clock) == nil)
        #expect(clock.now >= .seconds(20))
        #expect(clock.tries == 11)
    }

    @Test func slowTriesStillGetTheWholeTimeout() async {
        let clock = Clock()
        #expect(await probe(clock, tryTakes: .seconds(6)) == nil)
        #expect(clock.tries == 3)
        #expect(clock.now == .seconds(22))
    }

    @Test func aCancelledProbeStopsAsking() async {
        let clock = Clock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await probe(clock)
        }
        #expect(await task.value == nil)
        #expect(clock.tries == 0)
    }

    @Test func tunAsksOnlyWhenTheHelperNeedsSomething() {
        #expect(HelperState.notInstalled.tunConsent == .install)
        #expect(HelperState.needsApproval.tunConsent == .approve)
        #expect(HelperState.ready.tunConsent == nil)
        #expect(HelperState.outdated.tunConsent == nil)
        #expect(HelperState.unavailable("x").tunConsent == nil)
    }
}
