import Foundation
import Network
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

/// Importing a link Veer already has, against a subscription served on 127.0.0.1 by the test.
@MainActor @Suite(.serialized)
struct SubscriptionImportTests {
    /// Serves `body` to any GET, counting requests.
    final class Server: @unchecked Sendable {
        let listener: NWListener
        var body: String
        private(set) var requests = 0
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init(body: String) throws {
            self.body = body
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [unowned self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    self.requests += 1
                    let payload = Data(self.body.utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/yaml\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }

        func start() async throws {
            listener.start(queue: .global())
            for _ in 0..<200 where port == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    static func subscription(nodes: Int) -> String {
        let names = (0..<nodes).map { "JP-\($0)" }
        return "proxies:\n" + names.map { "  - {name: \($0), type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: p}\n" }.joined()
            + "proxy-groups:\n  - {name: Proxy, type: select, proxies: [\(names.joined(separator: ", "))]}\nrules:\n  - MATCH,Proxy\n"
    }

    static func store() throws -> ProxyStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-import-\(UUID().uuidString)")
        let paths = VeerPaths(root: root)
        try paths.prepare()
        let defaults = UserDefaults(suiteName: "veer-import-\(UUID().uuidString)")!
        return ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in throw EditorError("System proxy forbidden in tests") }),
                          binary: nil, defaults: defaults)
    }

    static func importLink(_ link: String, into store: ProxyStore) async throws {
        store.importText = link
        store.importFromText()
        try await Task.sleep(for: .milliseconds(20))
        let end = Date().addingTimeInterval(10)
        while store.importing || !store.updatingProfiles.isEmpty {
            guard Date() < end else { throw EditorError("import did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func theSameLinkAgainUpdatesTheProfileInPlaceAndKeepsWhatTheUserMade() async throws {
        let server = try Server(body: Self.subscription(nodes: 2))
        try await server.start()
        defer { server.listener.cancel() }
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        // A token in the query, and parameters in an order that must not be changed.
        let link = "http://127.0.0.1:\(server.port)/api/sub?token=AbC123&flag=meta&b=2&a=1"
        try await Self.importLink(link, into: store)
        let first = try #require(store.profiles.first)
        #expect(store.profiles.count == 1 && first.nodeCount == 2)
        #expect(store.profileStore.subscriptionURL(of: first.id)?.absoluteString == link)
        store.setNode("JP-1", included: false, in: first.id)
        store.profiles = store.profiles.map { var renamed = $0; renamed.name = "My JP"; return renamed }
        try store.profileStore.saveInfo(store.profiles[0])

        server.body = Self.subscription(nodes: 3)
        try await Self.importLink("  \(link)  ", into: store)
        #expect(store.profiles.count == 1, "no second profile for the same link")
        let updated = try #require(store.profiles.first)
        #expect(updated.id == first.id && updated.name == "My JP" && updated.nodeCount == 3)
        #expect(store.layer(of: first.id).excludedNodes == ["JP-1"])
        #expect(store.activity?.kind == .reimported(reloaded: false) && store.activity?.message.contains("My JP") == true)
        #expect(!store.showingImport)
        #expect(try store.profileStore.text(of: first.id).contains("JP-2"))

        // Any other link, even one that differs only in a query value, is another subscription.
        try await Self.importLink("http://127.0.0.1:\(server.port)/api/sub?token=AbC124&flag=meta&b=2&a=1", into: store)
        #expect(store.profiles.count == 2)
    }

    @Test func existingCopiesOfOneLinkMergeOnlyWhereNothingOfTheUsersIsLost() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let link = try #require(URL(string: "https://sub.example.com/s?token=x"))
        var copies: [Profile] = []
        for (index, name) in ["Old", "Edited", "Newest"].enumerated() {
            let profile = Profile(name: name, isSubscription: true, updatedAt: Date(timeIntervalSince1970: Double(index) * 1000), nodeCount: 2)
            try store.profileStore.save(profile, text: Self.subscription(nodes: 2))
            try store.profileStore.setSubscriptionURL(link, for: profile.id)
            copies.append(profile)
        }
        let other = Profile(name: "Other", isSubscription: true, nodeCount: 2)
        try store.profileStore.save(other, text: Self.subscription(nodes: 2))
        try store.profileStore.setSubscriptionURL(try #require(URL(string: "https://sub.example.com/s?token=y")), for: other.id)
        store.profiles = store.profileStore.loadAll()
        store.setNode("JP-0", included: false, in: copies[1].id)
        store.activeProfileID = copies[0].id

        let groups = store.duplicateProfiles()
        #expect(groups.count == 1 && groups[0].count == 3)
        let plan = try #require(store.mergePlan(groups[0]))
        #expect(plan.keep.id == copies[0].id, "the profile in use is kept")
        #expect(plan.remove.map(\.id) == [copies[2].id])
        #expect(plan.keptWithChanges.map(\.id) == [copies[1].id])

        let agent = try agentWithRuntimeHistory(in: copies[2], store: store)
        let undoManager = UndoManager()
        agent.changes.manager = undoManager
        let turn = try #require(agent.current?.turns.first)
        let sessionID = try #require(agent.current?.id)
        agent.changes.made("Runtime change", id: turn.id, group: sessionID, undoTo: false) { _ in false }
        #expect(undoManager.canUndo)
        #expect(agent.canUndo)
        let removed = try store.mergeDuplicates(plan)
        #expect(store.profiles.map(\.name).sorted() == ["Edited", "Old", "Other"])
        #expect(store.layer(of: copies[1].id).excludedNodes == ["JP-0"])
        #expect(agent.current?.profileID == copies[0].id)
        #expect(!agent.canUndo)
        #expect(!undoManager.canUndo)
        #expect(store.restoreMergedCopies(removed).isEmpty)
        #expect(store.profiles.map(\.name).sorted() == ["Edited", "Newest", "Old", "Other"])
        #expect(store.profileStore.subscriptionURL(of: copies[2].id) == link)
        #expect(agent.current?.profileID == copies[0].id)
        #expect(agent.canUndo)
    }

    private func agentWithRuntimeHistory(in profile: Profile, store: ProxyStore) throws -> AgentStore {
        let defaults = try #require(UserDefaults(suiteName: "veer-merge-agent-\(UUID().uuidString)"))
        let agent = AgentStore(proxy: store, defaults: defaults, persist: false)
        var session = Session(title: profile.name, source: .sample, text: try store.profileStore.text(of: profile.id))
        session.profileID = profile.id
        // Older conversations lack an origin on each runtime action. Merging preserves that origin.
        var run = RuntimeRun(steps: [.mode("direct")])
        run.items[0].state = .done
        run.items[0].undo = .mode("rule")
        session.turns = [Turn(prompt: "direct", mode: .local, steps: [], outcome: .runtime(run))]
        agent.sessions = [session]
        agent.selectedID = session.id
        return agent
    }

    @Test func anOldMergeConfirmationCannotRemoveAProfileWithADifferentLink() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let link = try #require(URL(string: "https://sub.example.invalid/first"))
        let first = Profile(name: "In use", isSubscription: true, nodeCount: 2)
        let copy = Profile(name: "Copy", isSubscription: true, nodeCount: 2)
        for profile in [first, copy] {
            try store.profileStore.save(profile, text: Self.subscription(nodes: 2))
            try store.profileStore.setSubscriptionURL(link, for: profile.id)
        }
        store.profiles = store.profileStore.loadAll()
        store.activeProfileID = first.id
        let copies = try #require(store.duplicateProfiles().first)
        let confirmed = try #require(store.mergePlan(copies))
        let newLink = try #require(URL(string: "https://sub.example.invalid/second"))
        try store.profileStore.setSubscriptionURL(newLink, for: copy.id)

        #expect(throws: EditorError.self) { try store.mergeDuplicates(confirmed) }
        #expect(store.profiles.count == 2)
        #expect(store.profileStore.subscriptionURL(of: copy.id) == newLink)
    }

    @Test func multipleMergesCanRestoreTogetherAndKeepFailuresForRetry() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        for group in ["first", "second"] {
            let link = try #require(URL(string: "https://sub.example.invalid/\(group)"))
            for name in [group, "\(group) copy"] {
                let profile = Profile(name: name, isSubscription: true, nodeCount: 2)
                try store.profileStore.save(profile, text: Self.subscription(nodes: 2))
                try store.profileStore.setSubscriptionURL(link, for: profile.id)
            }
        }
        store.profiles = store.profileStore.loadAll()
        let plans = store.duplicateProfiles().compactMap(store.mergePlan)
        let removed = try plans.flatMap(store.mergeDuplicates)
        try #require(removed.count == 2)
        #expect(store.profiles.count == 2)

        let index = try Data(contentsOf: store.paths.profileIndex)
        try Data("temporarily unreadable".utf8).write(to: store.paths.profileIndex)
        let afterIndexError = store.restoreMergedCopies(removed)
        #expect(afterIndexError.map(\.profile.id) == removed.map(\.profile.id))
        #expect(store.profiles.count == 2, "the sheet must stay open with both recovery copies")
        try index.write(to: store.paths.profileIndex, options: .atomic)

        let blocked = store.paths.profiles.appendingPathComponent("\(removed[0].profile.id.uuidString).yaml")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let remaining = store.restoreMergedCopies(removed)
        #expect(remaining.map(\.profile.id) == [removed[0].profile.id])
        #expect(store.profiles.count == 3)
        #expect(store.profileStore.subscriptionURL(of: removed[0].profile.id) == nil)
        try FileManager.default.removeItem(at: blocked)
        #expect(store.restoreMergedCopies(remaining).isEmpty)
        #expect(store.profiles.count == 4)
        for item in removed {
            #expect(try store.profileStore.text(of: item.profile.id) == item.text)
            #expect(store.profileStore.subscriptionURL(of: item.profile.id) == item.link)
        }
    }

    @Test func mergingProtectsUnreadableRoutingAndKeepsAllFilesIfTheIndexCannotBeWritten() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let link = try #require(URL(string: "https://sub.example.invalid/group"))
        let profiles = ["Current", "Copy", "Unreadable"].map { Profile(name: $0, isSubscription: true, nodeCount: 2) }
        for profile in profiles {
            try store.profileStore.save(profile, text: Self.subscription(nodes: 2))
            try store.profileStore.setSubscriptionURL(link, for: profile.id)
        }
        let unreadable = store.paths.routing.appendingPathComponent("\(profiles[2].id.uuidString).json")
        try Data("corrupt layer".utf8).write(to: unreadable)
        store.profiles = store.profileStore.loadAll()
        store.activeProfileID = profiles[0].id
        let copies = try #require(store.duplicateProfiles().first)
        let plan = try #require(store.mergePlan(copies))
        #expect(plan.remove.map(\.id) == [profiles[1].id])
        #expect(plan.keptWithChanges.map(\.id) == [profiles[2].id])

        // A malformed index must not trigger cleanup or recreation from a partial list.
        let invalid = Data("corrupt index".utf8)
        try invalid.write(to: store.paths.profileIndex)
        #expect(throws: (any Error).self) { try store.mergeDuplicates(plan) }
        #expect(try Data(contentsOf: store.paths.profileIndex) == invalid)
        for profile in profiles {
            #expect(try store.profileStore.text(of: profile.id) == Self.subscription(nodes: 2))
            #expect(store.profileStore.subscriptionURL(of: profile.id) == link)
        }
    }

    @Test func aLateUpdateDoesNotRecreateADeletedProfile() async throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let profile = Profile(name: "Deleted", isSubscription: true, nodeCount: 2)
        try store.profileStore.save(profile, text: Self.subscription(nodes: 2))
        store.profiles = store.profileStore.loadAll()
        store.showActivity(Activity(profileID: profile.id, name: profile.name, kind: .updating))
        store.delete(profile.id)

        let text = Self.subscription(nodes: 3)
        let response = SubscriptionResponse(text: text, headers: [:])
        try await store.save(response, ConfigImporter.normalize(text), into: profile, reimport: false)

        #expect(store.profiles.isEmpty)
        #expect(store.profileStore.loadAll().isEmpty)
        #expect(store.activity == nil)
    }
}
