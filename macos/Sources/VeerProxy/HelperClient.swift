import Foundation
#if os(macOS)
import ServiceManagement
import VeerCore
import VeerHelperKit
#endif

/// How the core runs: as the user (`CoreProcess`) or as root through the helper (`HelperCore`).
public protocol CoreRunning: AnyObject, Sendable {
    /// The core's latest output, oldest first.
    var tail: [String] { get }
    /// Starts the core with the config at `config`. `onExit` runs only when the core stops on
    /// its own: its status and last lines.
    func start(config: URL, onExit: @escaping @Sendable (Int32, [String]) -> Void) async throws
    func stop()
}

#if os(macOS)
extension CoreProcess: CoreRunning {}
#endif

/// Where the privileged helper stands.
public enum HelperState: Equatable, Sendable {
    case notInstalled
    /// Registered; the user has to allow it in System Settings → General → Login Items.
    case needsApproval
    case ready
    /// Installed, but an older version than this Veer expects.
    case outdated
    case unavailable(String)

    /// What the person has to agree to before TUN can use the helper.
    public enum TUNConsent: Equatable, Sendable {
        case install, approve
    }

    /// Whether this state is the helper becoming usable while TUN waits for it, so that the running
    /// core should start again through it. Only on the change: a ready helper that failed would
    /// otherwise restart the core every time this is asked.
    public func finishesTUNSetup(from previous: HelperState?, tunEnabled: Bool, tunActive: Bool, running: Bool) -> Bool {
        self == .ready && previous != nil && previous != .ready && tunEnabled && !tunActive && running
    }

    public var tunConsent: TUNConsent? {
        switch self {
        case .notInstalled: .install
        case .needsApproval: .approve
        case .ready, .outdated, .unavailable: nil
        }
    }
}

// The helper is macOS only; iOS has no privileged helper, TUN or launchd.
#if os(macOS)
/// Talks to the privileged helper: registers it with SMAppService (or installs it by hand when
/// that cannot work, as with a development signature), and calls it over XPC.
public final class HelperClient: @unchecked Sendable {
    public static let shared = HelperClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    /// Installed by hand into /Library (see `installManually`).
    public var isInstalledManually: Bool { FileManager.default.fileExists(atPath: HelperConstants.installedPlist) }

    public func state() async -> HelperState {
        if !isInstalledManually {
            switch service.status {
            case .notRegistered: return .notInstalled
            case .requiresApproval: return .needsApproval
            // Also what a daemon that was never registered reports; only a missing plist is a broken app.
            case .notFound:
                let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConstants.plistName)")
                return FileManager.default.fileExists(atPath: plist.path)
                    ? .notInstalled : .unavailable(String(localized: "应用包里缺少后台服务，请重新安装 Veer。"))
            case .enabled: break
            @unknown default: return .notInstalled
            }
        }
        guard let version = try? await version() else {
            return .unavailable(String(localized: "后台服务没有回应。可以在设置里重新安装它。"))
        }
        return HelperConstants.compatibleVersions.contains(version) ? .ready : .outdated
    }

    /// Registers the helper with launchd through SMAppService. Afterwards the user approves it
    /// in System Settings; `state()` then reports `.ready`.
    public func register() throws {
        do { try service.register() } catch {
            // The first registration "fails" with EPERM while it waits for the user's approval.
            if service.status == .requiresApproval { return }
            throw EditorError(String(localized: "无法注册后台服务：\(error.localizedDescription)"))
        }
    }

    public func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Removes the SMAppService registration, if there is one.
    public func unregister() async throws {
        guard service.status != .notRegistered else { return }
        try await service.unregister()
        disconnect()
    }

    // MARK: Installing by hand

    /// Copies the helper and Mihomo from the app into /Library/PrivilegedHelperTools, writes the
    /// launchd plist and loads it, with one administrator password prompt. Used when SMAppService
    /// refuses the registration. The script is fixed text; only quoted paths from this app go in.
    public func installManually(app: URL = Bundle.main.bundleURL) async throws {
        let helper = app.appendingPathComponent("Contents/Library/LaunchServices/\(HelperConstants.label)").path
        let core = app.appendingPathComponent("Contents/Resources/bin/mihomo").path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(HelperConstants.label)</string>
        <key>Program</key><string>\(HelperConstants.installedHelper)</string>
        <key>MachServices</key><dict><key>\(HelperConstants.label)</key><true/></dict>
        </dict></plist>
        """
        // A registered SMAppService helper holds the same label and Mach service.
        try? await unregister()
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(HelperConstants.label).plist")
        try Data(plist.utf8).write(to: staged)
        let commands = [
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null; true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp \(Self.quoted(helper)) \(Self.quoted(HelperConstants.installedHelper))",
            "/bin/cp \(Self.quoted(core)) \(Self.quoted(HelperConstants.installedCore))",
            "/bin/cp \(Self.quoted(staged.path)) \(Self.quoted(HelperConstants.installedPlist))",
            "/usr/sbin/chown root:wheel \(Self.quoted(HelperConstants.installedHelper)) \(Self.quoted(HelperConstants.installedCore)) \(Self.quoted(HelperConstants.installedPlist))",
            "/bin/chmod 755 \(Self.quoted(HelperConstants.installedHelper)) \(Self.quoted(HelperConstants.installedCore))",
            "/bin/chmod 644 \(Self.quoted(HelperConstants.installedPlist))",
            "/bin/launchctl bootstrap system \(Self.quoted(HelperConstants.installedPlist))",
        ]
        try await Self.runAsAdministrator(commands.joined(separator: " && "))
        disconnect()
    }

    /// Stops and removes a hand-installed helper.
    public func uninstallManually() async throws {
        let commands = [
            "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null; true",
            "/bin/rm -f \(Self.quoted(HelperConstants.installedPlist)) \(Self.quoted(HelperConstants.installedHelper)) \(Self.quoted(HelperConstants.installedCore))",
        ]
        try await Self.runAsAdministrator(commands.joined(separator: " && "))
        disconnect()
    }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `do shell script … with administrator privileges`: macOS asks for the password itself.
    private static func runAsAdministrator(_ command: String) async throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        let failure: String? = await Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            // -128: the user cancelled the password prompt.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return String(localized: "已取消。") }
            return error[NSAppleScript.errorMessage] as? String ?? String(localized: "安装失败。")
        }.value
        if let failure { throw EditorError(failure) }
    }

    // MARK: XPC

    /// One connection kept while Veer uses the helper: the helper stops the core ten seconds
    /// after the last connection goes away.
    private func remote() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: VeerHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            connection.interruptionHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    public func disconnect() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    /// The helper's proxy, failing `fail` (once) when the connection breaks.
    private func helper(_ fail: @escaping @Sendable (Error) -> Void) -> VeerHelperProtocol? {
        remote().remoteObjectProxyWithErrorHandler { error in fail(error) } as? VeerHelperProtocol
    }

    public func version() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = Once(continuation)
            guard let helper = helper({ once.resume(throwing: $0) }) else { return once.resume(throwing: Self.unreachable) }
            helper.version { once.resume(returning: $0) }
            // A helper that never answers (not loaded) must not hang the caller.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(throwing: Self.unreachable) }
        }
    }

    public func start(config: Data, geodata: String) async throws {
        let failure: String? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            let once = Once(continuation)
            guard let helper = helper({ once.resume(throwing: $0) }) else { return once.resume(throwing: Self.unreachable) }
            helper.start(config: config, geodata: geodata) { once.resume(returning: $0) }
        }
        // The helper runs as root with no language of its own; its fixed replies are translated here.
        if let failure { throw EditorError(Bundle.main.localizedString(forKey: failure, value: failure, table: nil)) }
    }

    public func status() async throws -> (running: Bool, lines: [String], exitStatus: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            guard let helper = helper({ once.resume(throwing: $0) }) else { return once.resume(throwing: Self.unreachable) }
            helper.status { once.resume(returning: ($0, $1, $2)) }
        }
    }

    /// Writes hot rule set files into the root core's home. A helper older than this Veer has no
    /// such call, so it is asked only after the helper reports this version.
    public func writeRuleSets(_ files: [String: String], replacingAll: Bool) async throws {
        guard try await version() == HelperConstants.version else { throw Self.unreachable }
        let payload = try HotRuleSetFiles.encode(files)
        let failure: String? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            let once = Once(continuation)
            guard let helper = helper({ once.resume(throwing: $0) }) else { return once.resume(throwing: Self.unreachable) }
            helper.writeRuleSets(payload, replacingAll: replacingAll) { once.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(throwing: Self.unreachable) }
        }
        if let failure { throw EditorError(Bundle.main.localizedString(forKey: failure, value: failure, table: nil)) }
    }

    /// Stops the root core and waits (at most three seconds) for it, so a quitting Veer does not
    /// leave routes behind.
    public func stopSynchronously() {
        let done = DispatchSemaphore(value: 0)
        let proxy = remote().synchronousRemoteObjectProxyWithErrorHandler { _ in done.signal() } as? VeerHelperProtocol
        proxy?.stop { done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    static let unreachable = EditorError(String(localized: "无法连接后台服务。"))
}

/// Resumes a continuation once, whichever of the reply, the error handler or the timeout comes first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

/// The core run as root by the helper, for TUN. The helper reports the core's state; a watch
/// every two seconds notices when it stopped on its own.
public final class HelperCore: CoreRunning, @unchecked Sendable {
    private let client: HelperClient
    private let geodata: URL
    private let lock = NSLock()
    private var lines: [String] = []
    private var watch: Task<Void, Never>?

    public init(client: HelperClient = .shared, geodata: URL) {
        self.client = client
        self.geodata = geodata
    }

    public var tail: [String] { lock.withLock { lines } }

    public func start(config: URL, onExit: @escaping @Sendable (Int32, [String]) -> Void) async throws {
        try await client.start(config: try Data(contentsOf: config), geodata: geodata.path)
        let client = client
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let status = try? await client.status() else { continue }
                self?.lock.withLock { self?.lines = status.lines }
                if !status.running {
                    onExit(status.exitStatus, status.lines)
                    return
                }
            }
        }
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        client.stopSynchronously()
    }
}
#endif
