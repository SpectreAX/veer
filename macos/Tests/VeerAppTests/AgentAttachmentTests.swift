import AppKit
import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

@MainActor struct AgentAttachmentTests {
    @Test func returnDoesNotSendWhileAttachmentsAreLoading() {
        let proxy = SnapshotRunner.sample()
        let agent = AgentStore(proxy: proxy, persist: false)
        agent.composerText = "example.com 走直连"
        agent.loadingAttachments = 1
        agent.send()
        #expect(agent.sessions.isEmpty)
        #expect(agent.composerText == "example.com 走直连")
    }

    @Test func imageClipboardEnablesPasteAndDeliversTheImage() {
        let textView = ComposerNSTextView()
        #expect(textView.readablePasteboardTypes.contains(.png))
        #expect(textView.readablePasteboardTypes.contains(.tiff))
        // A named pasteboard avoids replacing the person's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let data = Data([1, 2, 3])
        pasteboard.setData(data, forType: .png)
        var received: Data?
        textView.onPasteImage = { received = $0 }
        #expect(textView.readSelection(from: pasteboard, type: .png))
        #expect(received == data)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
    func fullPermissionDirectSwitchCanBeUndoneAndRedone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veer-agent-test-\(UUID().uuidString)")
        let paths = VeerPaths(root: folder)
        let profile = Profile(name: "Fixture", isSubscription: false, nodeCount: 2)
        try ProfileStore(paths: paths).save(profile, text: """
        dns:
          enable: false
        proxies:
          - {name: First, type: http, server: 127.0.0.1, port: 9}
          - {name: Second, type: http, server: 127.0.0.1, port: 9}
        proxy-groups:
          - {name: mini4k, type: select, proxies: [First, Second]}
        rules:
          - DOMAIN-SUFFIX,mini4k.net,mini4k
          - MATCH,DIRECT
        """)
        let suite = "veer-agent-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]))
        // No real network service changes are possible, even if a later regression requests one.
        let proxy = ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in throw EditorError("System proxy forbidden in tests") }),
                               binary: binary, defaults: defaults)
        defer {
            proxy.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        proxy.settings.mixedPort = try #require(Ports.free())
        proxy.settings.tun = false
        proxy.showExitIP = false
        proxy.delayURL = "http://127.0.0.1:9/generate_204"
        proxy.start()
        try await waitUntil("core start") { proxy.isRunning }
        try await proxy.choose("Second", in: "mini4k")
        let agent = AgentStore(proxy: proxy, engine: EditorEngine(validator: MihomoValidator(binary: binary)), defaults: defaults, persist: false)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        agent.changes.manager = undoManager
        agent.useAI = false
        agent.executionMode = .full
        agent.send("mini4k.net 走直连")
        do {
            try await waitUntil("DIRECT apply") { proxy.groups.first(where: { $0.name == "mini4k" })?.now == "DIRECT" }
        } catch {
            Issue.record("Isolated state: \(String(describing: agent.current?.turns)), notice: \(proxy.notice ?? "none")")
            throw error
        }
        agent.undo()
        try await waitUntil("undo") { proxy.groups.first(where: { $0.name == "mini4k" })?.now == "Second" && !agent.isReversing }
        agent.redo()
        try await waitUntil("redo") {
            proxy.groups.first(where: { $0.name == "mini4k" })?.now == "DIRECT" && !agent.isReversing
        }
        try await checkMenuAndProposalReversals(agent, proxy: proxy, profileID: profile.id, undoManager: undoManager)
        #expect(!proxy.systemProxyOn)
        #expect(!proxy.tunActive)
    }

    private func checkMenuAndProposalReversals(_ agent: AgentStore, proxy: ProxyStore, profileID: UUID, undoManager: UndoManager) async throws {
        let previousCount = agent.current?.turns.count ?? 0
        undoManager.undo()
        undoManager.redo()
        undoManager.undo()
        try await waitUntil("rapid menu reversals") {
            proxy.groups.first(where: { $0.name == "mini4k" })?.now == "Second" && !agent.isReversing
        }
        let notes = agent.current?.turns.dropFirst(previousCount).compactMap { turn -> String? in
            if case .note(let message) = turn.outcome { return message }
            return nil
        }
        #expect(notes == [String(localized: "已撤销这项修改，分流恢复到之前的状态。"), String(localized: "已重新应用这项修改。"),
                          String(localized: "已撤销这项修改，分流恢复到之前的状态。")])
        #expect(undoManager.canRedo)
        #expect(proxy.layer(of: profileID).edits.first?.enabled == false)

        undoManager.redo()
        try await waitUntil("before using the proposal card") { !agent.isReversing }
        var laterRun = RuntimeRun(steps: [.mode(ProxyStore.Mode.rule.rawValue)])
        laterRun.items[0].state = .done
        laterRun.items[0].undo = .mode(ProxyStore.Mode.direct.rawValue)
        let laterTurn = Turn(prompt: "mode", mode: .local, steps: [], outcome: .runtime(laterRun))
        agent.current?.turns.append(laterTurn)
        let proposalID = try #require(agent.current?.turns.first { $0.proposal?.status == .written }?.id)
        agent.undoProposal(turnID: proposalID)
        try await waitUntil("proposal card undo") { !agent.isReversing }
        #expect(try await proxy.controller?.mode() == ProxyStore.Mode.rule.rawValue)
        #expect(proxy.layer(of: profileID).edits.first?.enabled == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil), arguments: [false, true])
    func runtimeActionsStayWithTheirProfile(switchBeforeReply: Bool) async throws {
        let rig = try await ProfileSwitchTests.rig()
        defer { ProfileSwitchTests.tearDown(rig) }
        let proxy = rig.store
        let secondText = try proxy.profileStore.text(of: rig.second.id)
        try proxy.profileStore.save(rig.second, text: "mode: global\n" + secondText)
        let transport = GatedTransport(answer: #"{"runtime":{"actions":[{"kind":"mode","mode":"direct"}]}}"#)
        let suite = "veer-agent-runtime-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agent = AgentStore(proxy: proxy, engine: EditorEngine(ai: AIClient(transport: transport)), defaults: defaults, persist: false)
        agent.settings = AISettings(provider: .ollama, model: "fixture-model")
        agent.useAI = true
        agent.searchSettings.enabled = false
        let undoManager = UndoManager()
        agent.changes.manager = undoManager
        proxy.start()
        try await waitUntil("first profile started") { proxy.isRunning }
        agent.send("切换到直连模式")
        let turn = try #require(agent.current?.turns.first)
        try await waitUntil("runtime model request") { await transport.requests == 1 || !agent.isRunning }
        try #require(await transport.requests == 1, "\(String(describing: agent.current?.turns.first?.outcome))")
        if switchBeforeReply {
            proxy.activate(rig.second.id)
            await proxy.coreConfigWork.finish()
            await transport.release()
            try await waitUntil("response after profile switch") {
                if case .runtime(let run) = agent.current?.turns.first?.outcome { return run.finished }
                return !agent.isRunning
            }
            guard case .runtime(let run) = agent.current?.turns.first?.outcome else {
                Issue.record("Expected a runtime reply, got \(String(describing: agent.current?.turns.first?.outcome))")
                return
            }
            #expect(run.items.first?.state == .failed)
            #expect(try await proxy.controller?.mode() == ProxyStore.Mode.global.rawValue)
            #expect(!undoManager.canUndo)
        } else {
            await transport.release()
            try await waitUntil("runtime change recorded") { undoManager.canUndo }
            proxy.activate(rig.second.id)
            // Undo is requested before the switch completes, while the old runtime action is still on the native stack.
            undoManager.undo()
            await proxy.coreConfigWork.finish()
            try await waitUntil("inactive profile undo refused") { !agent.isReversing }
            #expect(try await proxy.controller?.mode() == ProxyStore.Mode.global.rawValue)
            #expect(agent.toast?.warning == true)
            proxy.activate(rig.first.id)
            await proxy.coreConfigWork.finish()
            try await proxy.switchMode(.direct)
            agent.undoRuntime(turnID: turn.id)
            try await waitUntil("card retry completed") { !agent.isReversing }
            #expect(try await proxy.controller?.mode() == ProxyStore.Mode.rule.rawValue)
        }
    }

    private func waitUntil(_ stage: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EditorError("Timed out waiting for isolated Agent state: \(stage)")
    }
}
