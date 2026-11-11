import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

@MainActor struct ArchivedConversationTests {
    @Test func deletingItsProfileArchivesAConversationAndClosesIt() throws {
        let proxy = SnapshotRunner.sample()
        let agent = AgentStore(proxy: proxy, persist: false)
        let other = try #require(proxy.profiles.first { $0.id != proxy.activeProfileID })
        var session = Session(title: "家里", source: .pasted, text: try proxy.effectiveText(of: other.id))
        session.profileID = other.id
        agent.sessions.insert(session, at: 0)
        agent.select(session.id)
        #expect(!agent.isArchived)

        proxy.delete(other.id)
        #expect(agent.isArchived)
        agent.composerText = "example.com 走直连"
        agent.send()
        #expect(agent.current?.turns.isEmpty == true)
        // Left where it was, rather than lost.
        #expect(agent.composerText == "example.com 走直连")
        #expect(!agent.canUndo)
        #expect(!agent.canRedo)

        // A new conversation goes to the profile in use, and the old one stays archived.
        agent.newThread()
        #expect(agent.selectedID != session.id)
        #expect(!agent.isArchived)
        #expect(agent.sessions.first { $0.id == session.id }.map(agent.isArchived) == true)
    }

    @Test func aConversationWithNoProfileIsArchived() {
        let agent = AgentStore(proxy: SnapshotRunner.sample(), persist: false)
        #expect(agent.isArchived(Session(title: "旧", source: .pasted, text: "")))
    }
}
