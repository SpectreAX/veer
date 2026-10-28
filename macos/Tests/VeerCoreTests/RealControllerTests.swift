import Foundation
import Testing
@testable import VeerCore

/// Applies a draft to a real running Mihomo and reads it back. Runs only with a core binary:
/// `VEER_MIHOMO_BIN` (a release, without PUT /rules) and/or `VEER_MIHOMO_RULES_BIN` (a build
/// with PUT /rules, MetaCubeX/mihomo#3373).
struct RealControllerTests {
    static let base = """
    mixed-port: 0
    proxies:
      - {name: JP, type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: US, type: ss, server: us.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 日本, type: select, proxies: [JP]}
      - {name: 美国, type: select, proxies: [US]}
    rules:
      - DOMAIN-SUFFIX,example.com,DIRECT
      - MATCH,DIRECT
    """

    static let draftText = base.replacingOccurrences(of: "rules:\n", with: "rules:\n  - DOMAIN-SUFFIX,netflix.com,日本\n  - DOMAIN-SUFFIX,openai.com,美国\n")

    /// Starts `binary` on a config with a controller; returns the controller and the process.
    static func start(_ binary: String) async throws -> (MihomoController, Process) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let port = Int.random(in: 20000...40000)
        let secret = UUID().uuidString
        let config = "external-controller: 127.0.0.1:\(port)\nsecret: \(secret)\n" + base
        try config.write(to: directory.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
        for _ in 0..<50 {
            if (try? await controller.version()) != nil { return (controller, process) }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw EditorError("core did not start")
    }

    static let draft = try! ConfigDocument.parse(draftText)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_RULES_BIN"] != nil))
    func rulesOnlyUpdateTakesEffectAndRestores() async throws {
        let (controller, process) = try await Self.start(ProcessInfo.processInfo.environment["VEER_MIHOMO_RULES_BIN"]!)
        defer { process.terminate() }
        #expect(try await controller.supportsRuleUpdate())
        let names = try await controller.proxyNames()
        #expect(MihomoController.missingTargets(in: Self.draft, running: names).isEmpty)
        try await controller.apply(Self.draftText, mode: .rules)
        #expect(MihomoController.matches(try await controller.rules(), draft: Self.draft))
        try await controller.restore(mode: .rules)
        #expect(try await controller.rules().count == 2, "restoring reloads the rules from the core's own file")
        // A policy the core does not run is refused and changes nothing.
        let unknown = Self.draftText.replacingOccurrences(of: "netflix.com,日本", with: "netflix.com,新组")
            .replacingOccurrences(of: "proxy-groups:\n", with: "proxy-groups:\n  - {name: 新组, type: select, proxies: [JP]}\n")
        await #expect(throws: EditorError.self) { try await controller.apply(unknown, mode: .rules) }
        #expect(try await controller.rules().count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
    func aReleaseCoreTakesTheWholeConfigAndRestores() async throws {
        let (controller, process) = try await Self.start(ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]!)
        defer { process.terminate() }
        #expect(try await controller.supportsRuleUpdate() == false)
        try await controller.apply(Self.draftText, mode: .config)
        #expect(MihomoController.matches(try await controller.rules(), draft: Self.draft))
        try await controller.restore(mode: .config)
        #expect(try await controller.rules().count == 2, "restoring reloads the core's own file")
    }
}
