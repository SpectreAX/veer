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
        proxy.start()
        try await waitUntil("core start") { proxy.isRunning }
        try await proxy.choose("Second", in: "mini4k")
        let agent = AgentStore(proxy: proxy, engine: EditorEngine(validator: MihomoValidator(binary: binary)), defaults: defaults, persist: false)
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
        try await waitUntil("undo") { proxy.groups.first(where: { $0.name == "mini4k" })?.now == "Second" }
        agent.redo()
        try await waitUntil("redo") { proxy.groups.first(where: { $0.name == "mini4k" })?.now == "DIRECT" }
        #expect(!proxy.systemProxyOn)
        #expect(!proxy.tunActive)
    }

    private func waitUntil(_ stage: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EditorError("Timed out waiting for isolated Agent state: \(stage)")
    }
}
