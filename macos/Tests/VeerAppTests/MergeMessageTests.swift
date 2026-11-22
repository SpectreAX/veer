import Testing
@testable import VeerApp
import VeerProxy

/// The duplicate-merge confirmation names what stays and, by name, every copy that goes: a copy may
/// have been renamed, and the row above names only the first one.
@MainActor struct MergeMessageTests {
    @Test func theConfirmationNamesTheKeptProfileAndEveryRemovedCopy() {
        let plan = MergePlan(keep: Profile(name: "Tokyo", isSubscription: true, nodeCount: 5),
                             remove: [Profile(name: "Tokyo Backup", isSubscription: true, nodeCount: 5),
                                      Profile(name: "Sydney Copy", isSubscription: true, nodeCount: 5)],
                             keptWithChanges: [])
        let message = ProfilesSheet.mergeMessage(plan)
        #expect(message.contains("“Tokyo”"))
        #expect(message.contains("“Tokyo Backup”") && message.contains("“Sydney Copy”"))
        #expect(message.contains("2"))
    }

    /// Found in the isolated sheet: Return confirmed the merge and a second Return closed the sheet, and
    /// Restore Copies with it. Close is the default only when nothing is waiting to be restored.
    @Test func closeIsTheReturnDefaultOnlyWithNothingToRestore() {
        #expect(ProfilesSheet.closeIsDefault(pendingCopies: 0))
        #expect(!ProfilesSheet.closeIsDefault(pendingCopies: 1))
        #expect(!ProfilesSheet.closeIsDefault(pendingCopies: 2))
    }

    @Test func copiesKeptForTheirOwnChangesAreCountedNotListedForRemoval() {
        let kept = Profile(name: "Edited Copy", isSubscription: true, nodeCount: 5)
        let plan = MergePlan(keep: Profile(name: "Tokyo", isSubscription: true, nodeCount: 5),
                             remove: [Profile(name: "Tokyo Backup", isSubscription: true, nodeCount: 5)], keptWithChanges: [kept])
        let message = ProfilesSheet.mergeMessage(plan)
        #expect(message.contains("“Tokyo Backup”"))
        #expect(!message.contains("Edited Copy"))
    }
}
