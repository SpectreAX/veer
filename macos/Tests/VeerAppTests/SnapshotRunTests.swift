import Testing
@testable import VeerApp

struct SnapshotRunTests {
    @Test func quittingASnapshotRunLeavesRealDataAlone() {
        #expect(AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_DIR": "/tmp/x"]))
        #expect(!AppDelegate.isSnapshotRun([:]))
        #expect(!AppDelegate.isSnapshotRun(["VEER_SNAPSHOT_SCENES": "04"]))
    }
}
