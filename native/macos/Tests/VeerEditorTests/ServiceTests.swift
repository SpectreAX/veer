import Foundation
import Testing
@testable import VeerEditor

@Test @MainActor func bundledServiceMissingFilesFailsWithoutFallback() async {
    let service = BundledEditorService(root: URL(fileURLWithPath: "/missing-veer-service"))
    do { _ = try await service.start(); Issue.record("Missing bundle unexpectedly started") }
    catch { #expect(error.localizedDescription.contains("内置编辑服务")) }
    service.stop(); service.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_BUNDLED_EDITOR_ROOT"] != nil)) @MainActor func bundledServiceRoundTripStopAndRestart() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VEER_BUNDLED_EDITOR_ROOT"])
    let service = BundledEditorService(root: URL(fileURLWithPath: path))
    defer { service.stop() }
    async let first = service.start()
    async let second = service.start()
    let clients = try await (first, second)
    let source = "proxy-groups:\n  - name: 日本出口\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n"
    let draft = try await clients.0.importDocument(source)
    #expect(draft.groups.first?.name == "日本出口")
    #expect(try await clients.1.inspect(draft, source: source).count == 1)
    let preview = try await clients.0.generate(draft, prompt: "Netflix 走日本", mode: "local", settings: AISettings(), source: source)
    #expect(preview.changed && preview.validation.status == "passed")
    let exported = try await clients.0.exportDocument(source, draft: Draft(groups: draft.groups, rules: preview.candidate))
    #expect(exported.hasPrefix(source.components(separatedBy: "rules:")[0]))
    service.stop(); service.stop()
    try await Task.sleep(for: .milliseconds(300))
    do { _ = try await clients.0.importDocument(source); Issue.record("Stopped service remains reachable") } catch {}
    let restarted = try await service.start()
    #expect(try await restarted.importDocument(source).rules.contains("MATCH"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_BUNDLED_EDITOR_ROOT"] != nil), arguments: [false, true]) @MainActor func bundledServiceFailedStartupCanRetry(timeout: Bool) async throws {
    let installed = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VEER_BUNDLED_EDITOR_ROOT"]))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-damaged-service-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for file in ["node", "mihomo"] {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bin/\(file)"), withDestinationURL: installed.appendingPathComponent("bin/\(file)"))
    }
    let entry = root.appendingPathComponent("native-host.mjs")
    try Data((timeout ? "setInterval(() => {}, 1000);" : "process.exit(2);").utf8).write(to: entry)
    let service = BundledEditorService(root: root)
    defer { service.stop() }
    do { _ = try await service.start(); Issue.record("Broken service unexpectedly started") }
    catch { #expect(error.localizedDescription.contains(timeout ? "启动超时" : "启动失败")) }
    try FileManager.default.removeItem(at: entry)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: installed.appendingPathComponent("native-host.mjs"))
    let client = try await service.start()
    #expect(try await client.importDocument("rules: [\"MATCH,DIRECT\"]").rules.contains("MATCH"))
}
