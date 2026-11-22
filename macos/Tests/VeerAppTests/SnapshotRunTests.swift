import Foundation
import Testing
@testable import VeerApp
import VeerProxy

struct SnapshotRunTests {
    @Test func quittingASnapshotRunLeavesRealDataAlone() {
        #expect(AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_DIR": "/tmp/x"]))
        #expect(!AppDelegate.isSnapshotRun([:]))
        #expect(!AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_SCENES": "04"]))
    }

    /// Only the snapshot branch is built here: the other one opens the person's real data folder.
    @MainActor @Test func aSnapshotRunBuildsTheAppsStoresOnThrowawayData() {
        let environment = ["VEER_SNAPSHOT_DIR": "/tmp/x"]
        let store = AppDelegate.makeStore(environment)
        let agent = AppDelegate.makeAgent(proxy: store, environment)
        let real = VeerPaths().root.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path

        #expect(store.paths.root.standardizedFileURL.path != real)
        #expect(store.paths.root.standardizedFileURL.path.hasPrefix(temporary))
        #expect(store.defaults !== UserDefaults.standard)
        #expect(store.binary == nil)
        #expect(store.profiles.isEmpty)

        #expect(agent.defaults !== UserDefaults.standard)
        #expect(agent.defaults !== store.defaults)
        #expect(agent.sessionStore.directory.standardizedFileURL.path.hasPrefix(store.paths.root.standardizedFileURL.path))
        #expect(agent.sessions.isEmpty)
    }
}
