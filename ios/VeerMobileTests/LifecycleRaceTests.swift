import Foundation
import Testing
@testable import VeerMobile

/// Pure lifecycle tests: no Mihomo, URLSession, sockets, Keychain, or filesystem root. Gates put
/// invalidations exactly at suspension points instead of relying on sleeps or scheduler timing.
@MainActor
struct LifecycleRaceTests {
    @Test
    func startStopStartOfSameProfileRejectsOldCompletion() async {
        let lifecycle = CoreLifecycle()
        let profile = UUID()
        let old = lifecycle.begin(profileID: profile)
        let gate = Gate()
        var events: [String] = []
        var running = false
        lifecycle.enqueue {
            events.append("old-start")
            await gate.suspend()
            if lifecycle.contains(old) { running = true; events.append("old-published") }
        }
        await gate.waitUntilSuspended()

        lifecycle.invalidate()
        lifecycle.enqueue { running = false; events.append("stop") }
        let new = lifecycle.begin(profileID: profile)
        lifecycle.enqueue {
            guard lifecycle.contains(new) else { return }
            running = true
            events.append("new-start")
        }
        #expect(!lifecycle.contains(old))
        #expect(old.profileID == new.profileID)
        #expect(old.generation != new.generation)
        gate.release()
        await lifecycle.settle()
        #expect(events == ["old-start", "stop", "new-start"])
        #expect(running)
    }

    @Test
    func activationDuringStartingBindsTheNewProfile() async {
        let lifecycle = CoreLifecycle()
        let first = lifecycle.begin(profileID: UUID())
        let gate = Gate()
        var published: [UUID] = []
        lifecycle.enqueue {
            await gate.suspend()
            if lifecycle.contains(first) { published.append(first.profileID) }
        }
        await gate.waitUntilSuspended()
        lifecycle.invalidate()
        lifecycle.enqueue {} // The drained stop between A and B.
        let second = lifecycle.begin(profileID: UUID())
        lifecycle.enqueue {
            if lifecycle.contains(second) { published.append(second.profileID) }
        }
        gate.release()
        await lifecycle.settle()
        #expect(first.profileID != second.profileID)
        #expect(published == [second.profileID])
    }

    @Test
    func reloadAndHotWritesStayOrderedAcrossSuspension() async {
        let lifecycle = CoreLifecycle()
        let token = lifecycle.begin(profileID: UUID())
        let gate = Gate()
        var events: [String] = []
        var hotLines: [String] = []
        lifecycle.enqueue {
            guard lifecycle.contains(token) else { return }
            events.append("reload-write")
            await gate.suspend()
            guard lifecycle.contains(token) else { return }
            hotLines = []
            events.append("reload-apply")
        }
        await gate.waitUntilSuspended()
        lifecycle.enqueue {
            guard lifecycle.contains(token) else { return }
            hotLines.append("first")
            events.append("hot-first")
        }
        lifecycle.enqueue {
            guard lifecycle.contains(token) else { return }
            hotLines.append("second")
            events.append("hot-second")
        }
        #expect(events == ["reload-write"])
        gate.release()
        await lifecycle.settle()
        #expect(events == ["reload-write", "reload-apply", "hot-first", "hot-second"])
        #expect(hotLines == ["first", "second"])
    }

    @Test
    func stopDrainsInFlightWriteAndInvalidatesQueuedMutationsBeforeRestart() async {
        let lifecycle = CoreLifecycle()
        let old = lifecycle.begin(profileID: UUID())
        let gate = Gate()
        var events: [String] = []
        var hotState: [String] = []
        lifecycle.enqueue {
            events.append("write-began")
            await gate.suspend() // An uncancellable detached file write/controller request.
            events.append("write-ended")
            guard lifecycle.contains(old) else { return }
            hotState = ["stale"]
            events.append("stale-published")
        }
        await gate.waitUntilSuspended()
        lifecycle.enqueue {
            guard lifecycle.contains(old) else { return }
            events.append("queued-hot-write")
        }
        lifecycle.invalidate()
        hotState = []
        lifecycle.enqueue { events.append("stop") }
        let new = lifecycle.begin(profileID: UUID())
        lifecycle.enqueue {
            guard lifecycle.contains(new) else { return }
            events.append("new-runtime-write")
            hotState = ["new"]
        }
        #expect(events == ["write-began"])
        gate.release()
        await lifecycle.settle()
        #expect(events == ["write-began", "write-ended", "stop", "new-runtime-write"])
        #expect(hotState == ["new"])
    }

    @Test
    func refreshCompletionAfterStopCannotResumeObservers() async {
        let lifecycle = CoreLifecycle()
        let token = lifecycle.begin(profileID: UUID())
        let gate = Gate()
        var observersStarted = false
        let startup = lifecycle.enqueue {
            await gate.suspend() // coreDidStart awaiting refresh().
            guard lifecycle.contains(token) else { return }
            observersStarted = true
        }
        await gate.waitUntilSuspended()
        lifecycle.invalidate()
        lifecycle.enqueue {}
        gate.release()
        await startup.value
        await lifecycle.settle()
        #expect(!observersStarted)
    }

    @Test
    func staleFailureCannotOverrideLaterRequest() async {
        let lifecycle = CoreLifecycle()
        let old = lifecycle.begin(profileID: UUID())
        let gate = Gate()
        var phase = "starting"
        lifecycle.enqueue {
            await gate.suspend() // A failed core start finishes its off-actor cleanup.
            guard lifecycle.contains(old) else { return }
            phase = "failed"
        }
        await gate.waitUntilSuspended()
        lifecycle.invalidate()
        lifecycle.enqueue {}
        let new = lifecycle.begin(profileID: UUID())
        lifecycle.enqueue {
            guard lifecycle.contains(new) else { return }
            phase = "running"
        }
        gate.release()
        await lifecycle.settle()
        #expect(phase == "running")
    }

    @Test
    func settleIncludesWorkSubmittedWhileItIsWaiting() async {
        let lifecycle = CoreLifecycle()
        let first = Gate()
        let second = Gate()
        var settled = false
        lifecycle.enqueue { await first.suspend() }
        await first.waitUntilSuspended()
        let waiter = Task { await lifecycle.settle(); settled = true }
        lifecycle.enqueue { await second.suspend() }
        first.release()
        await second.waitUntilSuspended()
        #expect(!settled)
        second.release()
        await waiter.value
        #expect(settled)
    }

    @MainActor
    private final class Gate {
        private var suspended = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspended = true
                arrival?.resume()
                arrival = nil
            }
        }

        func waitUntilSuspended() async {
            if suspended { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }
}
