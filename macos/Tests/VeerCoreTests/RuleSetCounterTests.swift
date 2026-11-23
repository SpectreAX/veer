import Darwin
import Foundation
import Testing
@testable import VeerCore

/// Rule set entry counts from the bundled core. Needs `VEER_MIHOMO_BIN` and network access to
/// GitHub; the inline and local-file cases need neither, but share the setup. Serialized: the
/// loopback tests check that no counting core or temporary folder is left once a count returns.
@Suite(.serialized) struct RuleSetCounterTests {
    static let config = """
    proxies:
      - {name: JP, type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 日本, type: select, proxies: [JP]}
    rule-providers:
      netflix: {type: http, behavior: domain, format: mrs, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs", path: ./ruleset/netflix.mrs, interval: 86400, proxy: 日本}
      private-list: {type: http, behavior: classical, format: text, url: "http://127.0.0.1:9/list.txt", path: ./ruleset/list.txt, interval: 86400}
      mine: {type: inline, behavior: domain, payload: [a.example, b.example, c.example]}
      local: {type: file, behavior: domain, path: ./ruleset/local.yaml}
    rules:
      - RULE-SET,netflix,日本
      - MATCH,DIRECT
    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
    func countsComeFromTheCoreInEveryFormat() async throws {
        let counter = RuleSetCounter(binary: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]!))
        let counts = await counter.count(try ConfigDocument.parse(Self.config), timeout: 40)
        guard case .entries(let netflix) = counts["netflix"] else {
            Issue.record("netflix: \(String(describing: counts["netflix"]))")
            return
        }
        #expect(netflix > 10, "the netflix set lists dozens of domains")
        #expect(counts["mine"] == .entries(3))
        #expect(counts["local"] == .localFile)
        guard case .failed = counts["private-list"] else {
            Issue.record("an unreachable set must fail, got \(String(describing: counts["private-list"]))")
            return
        }
    }

    @Test func aConfigWithoutDownloadsNeedsNoCore() async throws {
        // A binary that does not exist: nothing here should try to start it.
        let counter = RuleSetCounter(binary: URL(fileURLWithPath: "/nonexistent/mihomo"))
        let text = Self.config.components(separatedBy: "\n").filter { !$0.contains("type: http") }.joined(separator: "\n")
            .replacingOccurrences(of: "  - RULE-SET,netflix,日本\n", with: "")
        let counts = await counter.count(try ConfigDocument.parse(text))
        #expect(counts == ["mine": .entries(3), "local": .localFile])
    }

    // MARK: Loopback: a rule set served on this Mac, and a controller port another program holds

    static var mihomo: URL? { ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"].map { URL(fileURLWithPath: $0) } }

    /// An HTTP server on 127.0.0.1 that answers every path with two domains after `delay` seconds.
    final class SetServer {
        let process = Process()
        let port: Int

        init(delay: Double = 0) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-u", "-c", """
            import time
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    time.sleep(\(delay))
                    body = b'a.example\\nb.example\\n'
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
            process.standardOutput = output
            try process.run()
            let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                process.terminate()
                throw EditorError("the loopback rule-set server did not start")
            }
            self.port = port
        }

        deinit { process.terminate() }
    }

    /// A listener on 127.0.0.1 that accepts and never answers: another program on the port.
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

    /// A downloaded set from `server`, an inline set and a local file.
    static func loopbackConfig(_ server: SetServer) throws -> ConfigDocument {
        try ConfigDocument.parse("""
        rule-providers:
          served: {type: http, behavior: domain, format: text, url: "http://127.0.0.1:\(server.port)/list.txt", path: ./ruleset/served.txt, interval: 86400}
          mine: {type: inline, behavior: domain, payload: [a.example, b.example, c.example]}
          local: {type: file, behavior: domain, path: ./ruleset/local.yaml}
        rules:
          - RULE-SET,served,DIRECT
          - MATCH,DIRECT
        """)
    }

    static func countingFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("veer-rulesets-") })
    }

    /// Whether a counting core is running (its folder is on its command line).
    static func countingCoreRunning() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "veer-rulesets-"]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    @Test(.enabled(if: mihomo != nil)) func aServedSetIsCountedAndNothingIsLeft() async throws {
        let server = try SetServer()
        let before = Self.countingFolders()
        let counts = await RuleSetCounter(binary: try #require(Self.mihomo)).count(try Self.loopbackConfig(server), timeout: 15)
        #expect(counts == ["served": .entries(2), "mine": .entries(3), "local": .localFile])
        #expect(Self.countingFolders() == before && !Self.countingCoreRunning())
    }

    @Test(.enabled(if: mihomo != nil)) func aSlowSetIsWaitedFor() async throws {
        let server = try SetServer(delay: 3)
        let began = ContinuousClock.now
        let counts = await RuleSetCounter(binary: try #require(Self.mihomo)).count(try Self.loopbackConfig(server), timeout: 15)
        #expect(counts["served"] == .entries(2), "\(counts)")
        #expect(ContinuousClock.now - began > .milliseconds(2500))
    }

    @Test(.enabled(if: mihomo != nil)) func aTakenControllerPortIsReportedAtOnceAndARetryCounts() async throws {
        let server = try SetServer()
        let held = try Holder(port: try #require(Ports.free()))
        var counter = RuleSetCounter(binary: try #require(Self.mihomo))
        counter.pickPort = { [port = held.port] in port }
        let before = Self.countingFolders()
        let began = ContinuousClock.now
        let counts = await counter.count(try Self.loopbackConfig(server), timeout: 15)
        let waited = ContinuousClock.now - began
        #expect(waited < .seconds(8), "took \(waited)")
        guard case .failed(let reason) = counts["served"] else {
            Issue.record("expected a failure, got \(String(describing: counts["served"]))")
            return
        }
        #expect(reason.contains(String(held.port)) && !reason.contains("秒仍未下载完成"), "\(reason)")
        // What needs no core is still counted.
        #expect(counts["mine"] == .entries(3) && counts["local"] == .localFile)
        #expect(Self.countingFolders() == before && !Self.countingCoreRunning())

        held.release()
        let retried = await RuleSetCounter(binary: try #require(Self.mihomo)).count(try Self.loopbackConfig(server), timeout: 15)
        #expect(retried["served"] == .entries(2), "\(retried)")
    }

    @Test func aCoreThatIgnoresTerminationDoesNotHoldUpCounting() async throws {
        let server = try SetServer()
        let held = try Holder(port: try #require(Ports.free()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("counting-core")
        // A core that reports a port conflict and won't exit on SIGTERM. It also exits on its
        // own eventually, so a regression fails instead of hanging the test suite.
        try """
        #!/usr/bin/python3
        import signal
        import time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print("listen tcp 127.0.0.1:\(held.port): bind: address already in use", flush=True)
        time.sleep(8)
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var counter = RuleSetCounter(binary: binary)
        counter.pickPort = { [port = held.port] in port }
        let before = Self.countingFolders()
        let started = ContinuousClock.now
        let counts = await counter.count(try Self.loopbackConfig(server))
        #expect(ContinuousClock.now - started < .seconds(5))
        guard case .failed(let reason) = counts["served"] else {
            Issue.record("expected a controller port conflict")
            return
        }
        #expect(reason.contains(String(held.port)))
        #expect(Self.countingFolders() == before && !Self.countingCoreRunning())
    }
}
