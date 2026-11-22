import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

/// The note under the rule picker in a profile's My Routing: it describes what is chosen, and with
/// the subscription's rules it still says what the template would do, since choosing it applies at once.
@MainActor struct RoutingNoteTests {
    @Test func theNoteFollowsTheChosenRules() {
        let subscription = ProfileDetailSheet.routingNote(template: nil)
        let template = ProfileDetailSheet.routingNote(template: RuleTemplate.standard)
        #expect(subscription != template)
        #expect(!subscription.isEmpty && !template.isEmpty)
    }

    /// The failure scene the screenshots use: an edit whose exit the refreshed profile lost is
    /// reported for the profile in use, and the edit that still applies is not.
    @Test func theConflictSceneReportsOnlyTheLostExit() throws {
        let store = SnapshotRunner.routingConflictStore(template: false)
        let replay = try #require(store.effective?.replay)
        #expect(replay.conflictCount == 1)
        #expect(store.layer(of: try #require(store.activeProfileID)).edits.count == 2)
    }

    @Test func aStoppedProfileReplaysItsSavedEditsAgainstEitherRuleSource() async throws {
        let store = SnapshotRunner.routingConflictStore(template: false)
        let profile = try #require(store.activeProfileID)
        let edits = store.layer(of: profile).edits
        let missingExit = try #require(edits.first?.id)
        #expect(!store.isRunning)

        for template in [RuleTemplate.standard, nil] {
            store.setTemplate(template, for: profile)
            _ = try await store.effectiveTextInBackground(of: profile)
            let replay = try #require(store.effective?.replay)
            let failed = try #require(replay.edits.first(where: { $0.id == missingExit }))
            #expect(failed.items.contains { if case .conflict = $0.outcome { true } else { false } })
            #expect(store.layer(of: profile).edits == edits)
            #expect(store.layer(of: profile).template == template)
        }
        #expect(!store.isRunning)
    }
}
