import Darwin
import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

/// A start whose ports another program holds, on the real `ProxyStore` with the bundled Mihomo
/// (`VEER_MIHOMO_BIN`), on this Mac only: one node on 127.0.0.1 that nothing answers, `dns.enable:
/// false`, every rule DIRECT, its own folder, the system proxy a stub that throws and the exit
/// check off. Nothing leaves this Mac and no system setting changes.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct StartPortConflictTests {
    /// Another program's listener on 127.0.0.1: it accepts connections and never answers.
    final class Holder {
        let port: Int
        private var fd: Int32

        init(port: Int) throws {
            self.port = port
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                      sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                      sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            guard fd >= 0, bound, listen(fd, 8) == 0 else {
                close(fd)
                throw EditorError("could not hold port \(port)")
            }
        }

        func release() {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    static func store(ruleSetURL: String? = nil) throws -> ProxyStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-port-conflict-\(UUID().uuidString)")
        let paths = VeerPaths(root: root)
        try paths.prepare()
        let dead = try #require(Ports.free())
        let text = """
        dns:
          enable: false
        proxies:
          - {name: N, type: http, server: 127.0.0.1, port: \(dead)}
        proxy-groups:
          - {name: G, type: select, proxies: [N]}

        """ + (ruleSetURL.map { url in
            "rule-providers:\n  slow: {type: http, behavior: domain, format: text, url: \"\(url)\", path: ./ruleset/slow.txt, interval: 86400}\n"
                + "rules:\n  - RULE-SET,slow,DIRECT\n  - MATCH,DIRECT\n"
        } ?? "rules:\n  - MATCH,DIRECT\n")
        let profiles = ProfileStore(paths: paths, secrets: FileKeyStore(url: paths.secrets))
        let profile = Profile(name: "Sample", isSubscription: false, nodeCount: 1)
        try profiles.save(profile, text: text)
        let defaults = UserDefaults(suiteName: "veer-port-conflict-\(UUID().uuidString)")!
        defaults.set(false, forKey: "showExitIP")
        defaults.set(profile.id.uuidString, forKey: "activeProfile")
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]!)
        let store = ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in throw EditorError("System proxy forbidden in tests") }),
                               binary: binary, defaults: defaults)
        var settings = store.settings
        settings.mixedPort = try #require(Ports.free())
        settings.tun = false
        store.settings = settings
        store.delayURL = "http://127.0.0.1:9/generate_204"
        return store
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// Whether a core started from this store's folder is still running.
    static func coreRunning(in store: ProxyStore) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", store.paths.core.path]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    static func stopAndClean(_ store: ProxyStore) async throws {
        store.stop()
        try await waitUntil(10) { !coreRunning(in: store) }
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    @Test func aTakenControllerPortFailsPromptlyAndTheNextStartRuns() async throws {
        let store = try Self.store()
        let held = try Holder(port: try #require(Ports.free()))
        store.pickControllerPort = { held.port }
        let began = ContinuousClock.now
        store.start()
        try await Self.waitUntil(75) { store.phase != .starting }
        let waited = ContinuousClock.now - began
        guard case .failed(let message, let log) = store.phase else {
            Issue.record("expected a failed start, got \(store.phase)")
            return try await Self.stopAndClean(store)
        }
        #expect(waited < .seconds(10), "the start took \(waited) to fail")
        #expect(message.contains(String(held.port)), "\(message)")
        #expect(!message.contains("GeoIP"), "\(message)")
        #expect(log.contains { $0.contains("External controller listen error") })
        // The failed start leaves nothing behind: no controller, no hot rule sets, no core process.
        #expect(store.controller == nil && store.hotSets == nil && !store.tunActive && !store.systemProxyOn)
        try await Self.waitUntil(5) { !Self.coreRunning(in: store) }
        #expect(!Self.coreRunning(in: store))
        #expect(!Ports.inUse(store.settings.mixedPort))

        // Once the port is free again, the next start runs.
        held.release()
        store.start()
        try await Self.waitUntil(30) { store.phase == .running }
        #expect(store.phase == .running, "\(store.phase)")
        #expect(store.controller?.base.port == held.port)
        try await Self.stopAndClean(store)
    }

    @Test func aProxyPortTakenAfterTheCheckFailsWithThePortMessage() async throws {
        let store = try Self.store()
        let mixed = store.settings.mixedPort
        store.start()
        // Taken after the check that start() makes and before the core binds it.
        let held = try Holder(port: mixed)
        try await Self.waitUntil(75) { store.phase != .starting }
        guard case .failed(let message, let log) = store.phase else {
            Issue.record("expected a failed start, got \(store.phase)")
            held.release()
            return try await Self.stopAndClean(store)
        }
        #expect(message.contains("端口 \(String(mixed)) 已被其他程序占用"), "\(message)")
        #expect(log.contains { $0.contains("listen tcp 127.0.0.1:\(mixed): bind: address already in use") })
        #expect(store.controller == nil && store.hotSets == nil && !store.systemProxyOn)
        try await Self.waitUntil(5) { !Self.coreRunning(in: store) }
        #expect(!Self.coreRunning(in: store))
        held.release()
        store.start()
        try await Self.waitUntil(30) { store.phase == .running }
        #expect(store.phase == .running, "\(store.phase)")
        try await Self.stopAndClean(store)
    }

    /// A rule set that is slow to download is not a conflict: the start waits for it, then runs.
    @Test func aSlowRuleSetIsStillWaitedFor() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "-u", "-c", """
        import time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                time.sleep(3)
                body = b'example.com\\n'
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
        try server.run()
        defer { server.terminate() }
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let port = try #require(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        let store = try Self.store(ruleSetURL: "http://127.0.0.1:\(port)/slow.txt")
        let began = ContinuousClock.now
        store.start()
        try await Self.waitUntil(40) { store.phase != .starting }
        let waited = ContinuousClock.now - began
        #expect(store.phase == .running, "\(store.phase)")
        #expect(waited > .milliseconds(2500), "ready after \(waited), before the rule set arrived")
        try await Self.stopAndClean(store)
    }

    @Test func aProxyPortAlreadyTakenFailsBeforeStarting() async throws {
        let store = try Self.store()
        let held = try Holder(port: store.settings.mixedPort)
        store.start()
        guard case .failed(let message, let log) = store.phase else {
            Issue.record("expected an immediate failure, got \(store.phase)")
            return try await Self.stopAndClean(store)
        }
        #expect(message.contains("端口 \(String(held.port)) 已被其他程序占用") && log.isEmpty)
        #expect(!Self.coreRunning(in: store))
        held.release()
        try await Self.stopAndClean(store)
    }
}

/// Reading a port conflict from the core's log, without a core.
@MainActor struct PortConflictLogTests {
    static let controllerLine = #"level=error msg="External controller listen error: listen tcp 127.0.0.1:31377: bind: address already in use""#
    static let proxyLine = #"level=error msg="Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use""#

    @Test func theControllerAndProxyPortsAreToldApart() {
        #expect(ProxyStore.portConflict(in: [Self.controllerLine], controllerPort: 31377, proxyPort: 7890) == .controller(31377))
        #expect(ProxyStore.portConflict(in: [Self.proxyLine], controllerPort: 31377, proxyPort: 7890) == .proxy(7890))
    }

    /// A slow rule set or provider is not a conflict: the start keeps waiting for it.
    @Test func otherErrorsAndOtherPortsAreNotAConflict() {
        let lines = [
            #"level=info msg="Start initial compatible provider default""#,
            #"level=error msg="[Provider] netflix pull error: Get \"https://example.com/netflix.mrs\": context deadline exceeded""#,
            #"level=warning msg="geodata download failed, retrying""#,
            // Another port that merely ends in the same digits.
            #"level=error msg="Start Mixed(http+socks) server error: listen tcp 127.0.0.1:17890: bind: address already in use""#,
        ]
        #expect(ProxyStore.portConflict(in: lines, controllerPort: 31377, proxyPort: 7890) == nil)
    }

    @Test func theMessagesNameThePortAndWhatToDo() {
        let controller = ProxyStore.message(for: .controller(31377))
        #expect(controller.contains("31377") && !controller.contains("GeoIP"))
        #expect(ProxyStore.message(for: .proxy(7890)) == ProxyStore.portInUseMessage(7890))
        #expect(ProxyStore.portInUseMessage(7890).contains("7890"))
    }
}
