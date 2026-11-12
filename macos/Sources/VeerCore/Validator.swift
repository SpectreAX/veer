import Foundation

public struct ValidationResult: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable { case passed, unavailable, failed }
    public let status: Status
    public let message: String
    public let detail: String?

    public init(status: Status, message: String, detail: String? = nil) {
        self.status = status
        self.message = message
        self.detail = detail
    }
}

public protocol ConfigValidating: Sendable {
    func validate(_ yaml: String) async -> ValidationResult
    var versionDescription: String? { get }
}

/// Runs the bundled Mihomo binary with `-t` in an isolated temporary directory. On iOS, where an
/// app cannot start a process, it asks the core linked into the app instead.
public struct MihomoValidator: ConfigValidating {
    #if os(macOS)
    public let binary: URL?
    public let timeout: TimeInterval
    /// A folder with GEO data the core already downloaded; linked in so a check does not fetch it again.
    public let geodata: URL?

    public init(binary: URL? = MihomoValidator.locateBinary(), timeout: TimeInterval = 20, geodata: URL? = MihomoValidator.locateGeodata()) {
        self.binary = binary
        self.timeout = timeout
        self.geodata = geodata
    }

    /// `VEER_GEODATA`, else the running core's home (Veer's `VeerPaths.core`).
    public static func locateGeodata() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VEER_GEODATA"] { return URL(fileURLWithPath: env) }
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Veer/core", isDirectory: true)
        return home.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Links the GEO files (not the rule-set caches, which a check could write to) into `directory`.
    static func linkGeodata(from source: URL, into directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return }
        for name in names where [".dat", ".mmdb", ".metadb"].contains(where: { name.lowercased().hasSuffix($0) }) {
            let file = source.appendingPathComponent(name)
            guard (try? fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else { continue }
            try? fm.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: file)
        }
    }

    public static func locateBinary() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"], fm.isExecutableFile(atPath: env) { return URL(fileURLWithPath: env) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/mihomo"), fm.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

    public var versionDescription: String? {
        guard let binary, let output = try? Self.run(binary, arguments: ["-v"], input: nil, timeout: 5, directory: nil).output else { return nil }
        return output.split(separator: "\n").first.map(String.init)
    }

    public func validate(_ yaml: String) async -> ValidationResult {
        guard let binary else {
            return ValidationResult(status: .unavailable, message: String(localized: "已通过结构检查；未找到内置 Mihomo 校验器，没有进行内核校验。"))
        }
        let timeout = timeout, geodata = geodata
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("veer-validate-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: directory) }
                if let geodata { Self.linkGeodata(from: geodata, into: directory) }
                let file = directory.appendingPathComponent("config.yaml")
                try Data(yaml.utf8).write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let result = try Self.run(binary, arguments: ["-t", "-d", directory.path, "-f", file.path], input: nil, timeout: timeout, directory: directory)
                if result.timedOut {
                    return ValidationResult(status: .failed, message: String(localized: "内核校验超过 \(Int(timeout)) 秒，可能在下载规则集或 GEO 数据。"))
                }
                if result.status == 0 {
                    return ValidationResult(status: .passed, message: String(localized: "已通过 Mihomo 配置测试 · 网络可达性未验证"))
                }
                let detail = Self.redact(result.output, yaml: yaml, directory: directory.path)
                let hint = detail.range(of: #"rule.?provider|download|dial|i/o timeout|no such host"#, options: [.regularExpression, .caseInsensitive]) != nil
                    ? String(localized: "可能是规则集下载失败。") : ""
                return ValidationResult(status: .failed, message: String(localized: "Mihomo 配置测试未通过。\(hint)"), detail: String(detail.suffix(1500)))
            } catch {
                return ValidationResult(status: .unavailable, message: String(localized: "已通过结构检查；无法运行 Mihomo 校验器，没有进行内核校验。"))
            }
        }.value
    }

    struct RunResult { let status: Int32; let output: String; let timedOut: Bool }

    static func run(_ binary: URL, arguments: [String], input: Data?, timeout: TimeInterval, directory: URL?) throws -> RunResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin"]
        if let directory { environment["HOME"] = directory.path; environment["TMPDIR"] = directory.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        let timedOut = process.isRunning
        if timedOut { process.terminate(); usleep(200_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return RunResult(status: process.terminationStatus, output: collected.string, timedOut: timedOut)
    }

    final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 64 * 1024 { data.append(chunk) }
        }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
    #else
    /// The linked core's check of a config: nil when it passes, else the core's error.
    public typealias Check = @Sendable (_ yaml: Data) -> String?

    let check: Check?
    public let versionDescription: String?

    /// Without `check` a config gets the structure check only, as on a Mac without the binary.
    public init(check: Check? = nil, version: String? = nil) {
        self.check = check
        versionDescription = version
    }

    public func validate(_ yaml: String) async -> ValidationResult {
        guard let check else {
            return ValidationResult(status: .unavailable, message: String(localized: "已通过结构检查；未找到内置 Mihomo 校验器，没有进行内核校验。"))
        }
        // The core's own check blocks while it parses, so it runs off the caller's thread.
        guard let error = await Task.detached(priority: .userInitiated, operation: { check(Data(yaml.utf8)) }).value else {
            return ValidationResult(status: .passed, message: String(localized: "已通过 Mihomo 配置测试 · 网络可达性未验证"))
        }
        // The app's container stands in for the temporary folder a Mac check runs in.
        let detail = Self.redact(error, yaml: yaml, directory: NSHomeDirectory())
        let hint = detail.range(of: #"rule.?provider|download|dial|i/o timeout|no such host"#, options: [.regularExpression, .caseInsensitive]) != nil
            ? String(localized: "可能是规则集下载失败。") : ""
        return ValidationResult(status: .failed, message: String(localized: "Mihomo 配置测试未通过。\(hint)"), detail: String(detail.suffix(1500)))
    }
    #endif

    /// Hides values of secret-looking keys and the temporary path.
    static func redact(_ output: String, yaml: String, directory: String) -> String {
        var secrets: [String] = []
        let pattern = ##"(?im)^\s*-?\s*(?:password|token|secret|uuid|private-?key|public-?key|auth|authorization|psk|server|url|obfs-password|short-id)\s*:\s*['"]?([^'"#\n]{3,})"##
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)) {
                if let range = Range(match.range(at: 1), in: yaml) { secrets.append(yaml[range].trimmingCharacters(in: .whitespaces)) }
            }
        }
        var text = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= 3 {
            text = text.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        return text.replacingOccurrences(of: directory, with: "[临时目录]").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
