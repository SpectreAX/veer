import Foundation
import Testing
@testable import VeerApp

/// When a latency test can start: the group and region buttons are disabled in the same cases, rather
/// than taking a click that does nothing.
@MainActor struct LatencyAvailabilityTests {
    @Test func aTestStartsOnlyWhenItCouldRun() throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let group = LatencyScope.group("节点选择"), region = LatencyScope.region("JP")
        #expect(store.canStartLatencyTest(group) && store.canStartLatencyTest(region))

        // Already testing: that scope waits, another one may start beside it.
        store.testingScopes.insert(group)
        #expect(!store.canStartLatencyTest(group) && store.canStartLatencyTest(region))
        store.testingScopes.remove(group)

        // During a profile switch nothing starts: its results would belong to the profile being replaced.
        store.switchingTo = UUID()
        #expect(!store.canStartLatencyTest(group) && !store.canStartLatencyTest(region))
        store.switchingTo = nil

        store.phase = .stopped
        #expect(!store.canStartLatencyTest(group))
    }
}
