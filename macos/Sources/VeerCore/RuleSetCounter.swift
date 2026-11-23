// macOS only: it starts the bundled core as a second process, which iOS apps cannot.
#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Yams

/// Counts the entries of a draft's rule sets the way Mihomo loads them, whatever their format
/// (`.mrs` is zstd-compressed binary). The bundled core starts in a temporary folder with only
/// those rule sets and a controller on a random local port, downloads them, and reports each
/// set's count; then it is stopped and the folder removed. Nothing else of the draft is given to it.
public struct RuleSetCounter: Sendable {
    public enum Count: Sendable, Equatable {
        case entries(Int)
        /// A `type: file` set: its file is on the machine that runs the config, not here.
        case localFile
        case failed(String)
    }

    let binary: URL
    /// Picks the counting core's controller port; tests hold a port and hand it over.
    var pickPort: @Sendable () -> Int? = { try? RuleSetCounter.freePort() }

    public init(binary: URL) { self.binary = binary }

    /// Counts by rule-provider key.
    public func count(_ document: ConfigDocument, timeout: TimeInterval = 30) async -> [String: Count] {
        guard let providers = (try? Yams.compose(yaml: document.text))?.mapping?["rule-providers"]?.mapping else { return [:] }
        var counts: [String: Count] = [:]
        var downloads: [(Node, Node)] = []
        for (index, (key, value)) in providers.enumerated() {
            guard let name = key.string, var definition = value.mapping else { continue }
            switch definition["type"]?.string {
            case "inline": counts[name] = .entries(definition["payload"]?.sequence?.count ?? 0)
            case "http":
                // The core downloads directly into its temporary folder; a named proxy does not exist there.
                definition["proxy"] = nil
                definition["path"] = Node(stringLiteral: "./sets/\(index)")
                downloads.append((key, .mapping(definition)))
            default: counts[name] = .localFile
            }
        }
        guard !downloads.isEmpty else { return counts }
        do {
            return try await download(downloads, timeout: timeout).merging(counts) { first, _ in first }
        } catch {
            let reason = (error as? EditorError)?.message ?? "无法启动内置 Mihomo。"
            for (key, _) in downloads { if let name = key.string { counts[name] = .failed(reason) } }
            return counts
        }
    }

    private func download(_ definitions: [(Node, Node)], timeout: TimeInterval) async throws -> [String: Count] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-rulesets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let port = pickPort() else { throw EditorError(String(localized: "无法为内置 Mihomo 分配本机端口。")) }
        let secret = UUID().uuidString
        let config: Node = .mapping(.init([
            (Node(stringLiteral: "external-controller"), Node(stringLiteral: "127.0.0.1:\(port)")),
            (Node(stringLiteral: "secret"), Node(stringLiteral: secret)),
            (Node(stringLiteral: "log-level"), Node(stringLiteral: "info")),
            (Node(stringLiteral: "rule-providers"), .mapping(.init(definitions))),
            (Node(stringLiteral: "rules"), .sequence(.init([Node(stringLiteral: "MATCH,DIRECT")]))),
        ]))
        try Yams.serialize(node: config, allowUnicode: true).write(to: directory.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", directory.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let output = MihomoValidator.OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
        let result: Result<[String: Count], Error>
        do {
            let names = definitions.compactMap(\.0.string)
            result = .success(try await Self.poll(names, controller: controller, process: process, output: output, timeout: timeout))
        } catch {
            result = .failure(error)
        }
        await Self.stop(process, exited: exited)
        return try result.get()
    }

    private static func poll(_ names: [String], controller: MihomoController, process: Process,
                             output: MihomoValidator.OutputBuffer, timeout: TimeInterval) async throws -> [String: Count] {
        var counts: [String: Count] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, process.isRunning {
            // Another program on the controller port: the core runs on without a controller, and
            // waiting would only end in a misleading download timeout. Counts already made stay.
            if let port = controller.base.port, Ports.listenFailed(on: port, in: output.string.split(separator: "\n")) {
                return Self.failing(names, in: counts, String(localized: "内置 Mihomo 的控制端口 \(String(port)) 被其他程序占用，未能计数。请重试。"))
            }
            // A short limit, because a program holding the port may accept and never answer.
            if let states = try? await controller.ruleProviders(timeout: 2) {
                for name in names where counts[name] == nil {
                    if let state = states[name], state.loaded { counts[name] = .entries(state.ruleCount) }
                    else if output.string.contains("initial rule provider \(name) error") { counts[name] = .failed("下载或解析失败") }
                }
                if counts.count == names.count { return counts }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return Self.failing(names, in: counts, process.isRunning ? "超过 \(Int(timeout)) 秒仍未下载完成" : "内置 Mihomo 意外退出")
    }

    private static func stop(_ process: Process, exited: DispatchSemaphore) async {
        guard process.isRunning else { return }
        // waitUntilExit can stall in Foundation's run loop. Use a bounded wait for the
        // termination notification, off Swift's cooperative executor.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                defer { continuation.resume() }
                process.terminate()
                if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .milliseconds(500))
                }
            }
        }
    }

    /// `counts` with every name not yet counted failed for `reason`.
    private static func failing(_ names: [String], in counts: [String: Count], _ reason: String) -> [String: Count] {
        var counts = counts
        for name in names where counts[name] == nil { counts[name] = .failed(reason) }
        return counts
    }

    /// A free TCP port on 127.0.0.1 for the counting core's controller, outside the ephemeral range
    /// (see `Ports.free()`), so another socket can't take it before the core binds it.
    static func freePort() throws -> Int {
        guard let port = Ports.free() else { throw EditorError(String(localized: "无法为内置 Mihomo 分配本机端口。")) }
        return port
    }
}
#endif
