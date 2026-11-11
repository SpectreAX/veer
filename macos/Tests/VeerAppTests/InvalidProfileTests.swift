import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

@MainActor struct InvalidProfileTests {
    static let invalid = "proxy-groups:\n  - {name: Auto, type: url-test, proxies: []}\n"

    @Test func managingProfilesLeavesTheFailedOnboardingStepWithoutStartingOrChangingAProfile() throws {
        let store = SnapshotRunner.sample()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        store.onboarding = .start
        store.phase = .failed("invalid config", log: [])
        let active = store.activeProfileID
        let profiles = store.profiles
        let settings = store.settings
        store.manageProfiles()
        #expect(store.onboarding == nil && store.page == .proxies)
        #expect(store.phase.isFailed && store.activeProfileID == active && store.profiles == profiles)
        #expect(store.settings == settings && !store.systemProxyOn && !store.tunActive)
    }

    @Test func managingProfilesWithNoProfileKeepsTheImportOnboarding() {
        let store = SnapshotRunner.sample(profiles: false)
        store.manageProfiles()
        #expect(store.onboarding == .addProfile && store.phase == .stopped)
    }

    @Test func importingAnEmptySubscriptionDoesNotReplaceTheExistingProfile() throws {
        let store = SnapshotRunner.sample()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let before = store.profiles
        let active = try #require(store.activeProfile)
        let original = try store.profileStore.text(of: active.id)
        let input = store.paths.root.appendingPathComponent("empty.yaml")
        try Self.invalid.write(to: input, atomically: true, encoding: .utf8)
        store.importFile(input)
        #expect(store.importError?.contains("Auto”没有节点或 Provider") == true)
        #expect(store.profiles == before)
        #expect(try store.profileStore.text(of: active.id) == original)
    }

    @Test func aDamagedSavedProfileFailsBeforeWritingARuntimeConfig() async throws {
        let sample = SnapshotRunner.sample()
        defer { try? FileManager.default.removeItem(at: sample.paths.root) }
        let profile = try #require(sample.activeProfile)
        try sample.profileStore.save(profile, text: Self.invalid)
        let defaults = UserDefaults(suiteName: "veer-invalid-start-\(UUID().uuidString)")!
        let store = ProxyStore(paths: sample.paths, systemProxy: SystemProxy(runner: { _ in
            Issue.record("A rejected profile must never touch system proxy settings")
            return ""
        }), binary: URL(fileURLWithPath: "/usr/bin/false"), defaults: defaults)
        store.settings.mixedPort = try #require(Ports.free())
        store.start()
        for _ in 0..<100 where store.phase == .starting { try await Task.sleep(for: .milliseconds(20)) }
        guard case .failed(let message, let log) = store.phase else { Issue.record("Expected preflight failure"); return }
        #expect(message.contains("Auto”没有节点或 Provider") && log.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.paths.runtimeConfig.path))
    }

    @Test(arguments: [false, true])
    func invalidSubscriptionUpdatesKeepTheLastSavedConfig(automatic: Bool) async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'proxy-groups:\\n  - {name: Auto, type: url-test, proxies: []}\\n'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let output = Pipe()
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let response = try #require(String(data: output.fileHandleForReading.availableData, encoding: .utf8))
        let port = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = SnapshotRunner.sample()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let profile = try #require(store.activeProfile)
        let original = try store.profileStore.text(of: profile.id)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/subscription"))
        try store.profileStore.setSubscriptionURL(url, for: profile.id)
        store.update(profile.id, automatic: automatic)
        for _ in 0..<200 where store.updatingProfiles.contains(profile.id) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.updatingProfiles.contains(profile.id))
        #expect(try store.profileStore.text(of: profile.id) == original)
        let saved = try #require(store.profileStore.loadAll().first { $0.id == profile.id })
        #expect(saved.nodeCount == profile.nodeCount && saved.updatedAt == profile.updatedAt)
        let message = automatic ? saved.updateError : store.notice
        #expect(message?.contains("Auto”没有节点或 Provider") == true)
    }
}
