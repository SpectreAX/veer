import Foundation

@MainActor
public final class BundledEditorService {
    private let root: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var startup: Task<EditorClient, any Error>?
    private var client: EditorClient?
    private var handshake: Data = Data()
    private var port: Int?
    private var generation = UUID()
    // Includes Node boot. The first launch after download can wait on macOS security scanning.
    private static let startupTimeout: Duration = .seconds(15)

    public init(root: URL) { self.root = root }

    public func start() async throws -> EditorClient {
        if let startup { return try await startup.value }
        if let client, process?.isRunning == true { return client }
        stop()
        let id = generation
        let task = Task { try await launch() }
        startup = task
        defer { if generation == id { startup = nil } }
        return try await task.value
    }

    private func launch() async throws -> EditorClient {
        let node = root.appendingPathComponent("bin/node")
        let entry = root.appendingPathComponent("native-host.mjs")
        let validator = root.appendingPathComponent("bin/mihomo")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.isExecutableFile(atPath: validator.path),
              FileManager.default.fileExists(atPath: entry.path) else {
            throw EditorFailure("应用缺少内置编辑服务，请重新构建或安装完整的 Veer 应用。")
        }
        let child = Process(), input = Pipe(), output = Pipe(), id = generation
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        child.executableURL = node
        child.arguments = [entry.path]
        child.currentDirectoryURL = root
        // Never inherit Node hooks, loader paths, proxy variables or API credentials.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            // EOF keeps firing with empty data; stop listening so a dead child cannot spin this handler.
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.receive(bytes)
            }
        }
        self.process = child; self.input = input; self.output = output
        do {
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["token": token]) + Data([10]))
            let deadline = ContinuousClock.now + Self.startupTimeout
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard generation == id, child.isRunning else { throw EditorFailure("内置编辑服务启动失败，请重试或重新安装应用。") }
                if let port {
                    let connected = try EditorClient(port: port, authToken: token)
                    self.client = connected
                    return connected
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw EditorFailure("内置编辑服务启动超时，请重试。")
        } catch {
            if generation == id { stop() }
            throw error
        }
    }

    private func receive(_ bytes: Data) {
        guard port == nil, handshake.count + bytes.count <= 1024 else { return }
        handshake.append(bytes)
        guard handshake.contains(10),
              let value = try? JSONSerialization.jsonObject(with: handshake) as? [String: Int],
              value["protocol"] == 1, let candidate = value["port"], (1...65535).contains(candidate) else { return }
        port = candidate
        output?.fileHandleForReading.readabilityHandler = nil
    }

    public func stop() {
        generation = UUID()
        startup?.cancel()
        startup = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        // Signal only our child, including a damaged entry that ignores stdin EOF.
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; client = nil; port = nil; handshake = Data()
    }
}
