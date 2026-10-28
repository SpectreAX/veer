import Foundation

/// The Mihomo child process: started with Veer's runtime config, stopped on request, and
/// reporting its last output lines when it exits on its own.
public final class CoreProcess: @unchecked Sendable {
    public let binary: URL
    public let home: URL
    private var process: Process?
    private var lines: [String] = []
    private var partial = ""
    private var stopping = false
    private let lock = NSLock()
    static let keptLines = 80

    public init(binary: URL, home: URL) {
        self.binary = binary
        self.home = home
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    /// The core's latest output, oldest first.
    public var tail: [String] { lock.withLock { lines } }

    /// Starts `mihomo -d home -f config`. `onExit` runs, off the main thread, only when the core
    /// exits without `stop()`: its status and last lines.
    public func start(config: URL, onExit: @escaping @Sendable (Int32, [String]) -> Void) throws {
        stop()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", home.path, "-f", config.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let (expected, tail) = self.lock.withLock { () -> (Bool, [String]) in
                let expected = self.stopping
                if self.process === process { self.process = nil }
                return (expected, self.lines)
            }
            if !expected { onExit(process.terminationStatus, tail) }
        }
        lock.withLock {
            lines = []
            partial = ""
            stopping = false
            self.process = process
        }
        do { try process.run() } catch {
            lock.withLock { self.process = nil }
            throw error
        }
    }

    /// Asks the core to quit, then kills it if it has not after two seconds.
    public func stop() {
        guard let process = lock.withLock({ () -> Process? in
            stopping = true
            return self.process
        }), process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        lock.withLock { if self.process === process { self.process = nil } }
    }

    private func append(_ text: String) {
        lock.withLock {
            let pieces = (partial + text).components(separatedBy: "\n")
            partial = pieces.last ?? ""
            lines.append(contentsOf: pieces.dropLast().filter { !$0.isEmpty })
            if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
        }
    }
}
