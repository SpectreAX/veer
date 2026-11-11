import Foundation
import VeerHelperKit

/// Veer's privileged helper: runs Mihomo as root so it can open a TUN device and set routes.
/// It serves only Veer signed by the same team, runs only a Mihomo signed by that team from a
/// root-owned copy, and stops the core when Veer goes away.
final class Helper: NSObject, NSXPCListenerDelegate, VeerHelperProtocol, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: HelperConstants.label)
    private let queue = DispatchQueue(label: "veer.helper")
    private var process: Process?
    private var lines: [String] = []
    private var partial = ""
    private var exitStatus: Int32 = 0
    private var stopping = false
    private var clients = 0
    /// Team of this helper's own signature; callers and the core must share it.
    private let team = CodeSigning.teamIdentifier()

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.main.run()
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let team else {
            NSLog("Veer helper: not signed with a team; refusing callers")
            return false
        }
        connection.setCodeSigningRequirement(CodeSigning.requirement(team: team, identifier: HelperConstants.appIdentifier))
        connection.exportedInterface = NSXPCInterface(with: VeerHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.disconnected() }
        queue.sync { clients += 1 }
        connection.resume()
        return true
    }

    /// Veer quit or crashed: give it ten seconds to come back, then stop the core so routes
    /// and DNS return to normal, and exit. launchd starts the helper again on the next call,
    /// from the binary then in the app, so an updated Veer gets its updated helper.
    private func disconnected() {
        queue.sync { clients -= 1 }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, clients <= 0 else { return }
            stopCore()
            exit(0)
        }
    }

    // MARK: Protocol

    func version(reply: @escaping @Sendable (String) -> Void) { reply(HelperConstants.version) }

    func start(config: Data, geodata: String, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in reply(startCore(config: config, geodata: geodata)) }
    }

    func stop(reply: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            stopCore()
            reply()
        }
    }

    func status(reply: @escaping @Sendable (Bool, [String], Int32) -> Void) {
        queue.async { [self] in reply(process?.isRunning == true, lines, exitStatus) }
    }

    func writeRuleSets(_ files: Data, replacingAll: Bool, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                let checked = try HotRuleSetFiles.decode(files)
                try Self.prepareHome()
                try HotRuleSetFiles.write(checked, replacingAll: replacingAll, into: HelperConstants.rootHome)
                reply(nil)
            } catch let error as HotRuleSetFilesError {
                reply(error.message)
            } catch {
                reply("后台服务无法写入规则集：\(error.localizedDescription)")
            }
        }
    }

    // MARK: Core

    private func startCore(config: Data, geodata: String) -> String? {
        stopCore()
        guard let team else { return "后台服务没有签名，无法确认内核来源。" }
        let manager = FileManager.default
        let home = HelperConstants.rootHome
        do {
            try Self.prepareHome()
            let core = try coreBinary(team: team, home: home)
            copyGeodata(from: geodata, to: home)
            let configPath = home + "/runtime.yaml"
            manager.createFile(atPath: configPath, contents: config, attributes: [.posixPermissions: 0o600])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: core)
            process.arguments = ["-d", home, "-f", configPath]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                queue.async { self.append(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { [self] process in
                queue.async {
                    self.exitStatus = process.terminationStatus
                    if self.process === process { self.process = nil }
                }
            }
            lines = []
            partial = ""
            exitStatus = 0
            try process.run()
            self.process = process
            return nil
        } catch {
            return "后台服务无法启动内核：\(error.localizedDescription)"
        }
    }

    /// The root core's home, owned by root and closed to everyone else.
    private static func prepareHome() throws {
        let manager = FileManager.default, home = HelperConstants.rootHome
        try manager.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700, .ownerAccountID: 0], ofItemAtPath: home)
    }

    /// The Mihomo to run: a hand-installed helper's root-owned copy, or the one inside Veer.app
    /// copied into the root home. Either must be signed by the helper's team.
    private func coreBinary(team: String, home: String) throws -> String {
        let requirement = CodeSigning.requirement(team: team)
        let manager = FileManager.default
        if manager.fileExists(atPath: HelperConstants.installedCore) {
            guard CodeSigning.satisfies(path: HelperConstants.installedCore, requirement: requirement) else {
                throw HelperError("已安装的内核签名不符，请重新安装后台服务。")
            }
            return HelperConstants.installedCore
        }
        // Contents/Library/LaunchServices/<helper> → Contents/Resources/bin/mihomo
        // launchd may pass BundleProgram's relative path as argv[0]; the executable path is absolute.
        let helper = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = contents.appendingPathComponent("Resources/bin/mihomo").path
        guard CodeSigning.satisfies(path: bundled, requirement: requirement) else {
            throw HelperError("Veer 里的内核签名不符，拒绝以管理员身份运行。")
        }
        let copy = home + "/mihomo"
        try? manager.removeItem(atPath: copy)
        try manager.copyItem(atPath: bundled, toPath: copy)
        try manager.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0], ofItemAtPath: copy)
        // Checked again after the copy, in the folder only root can write.
        guard CodeSigning.satisfies(path: copy, requirement: requirement) else { throw HelperError("复制后的内核签名不符。") }
        return copy
    }

    private func copyGeodata(from folder: String, to home: String) {
        let manager = FileManager.default
        for name in HelperConstants.geodataFiles {
            let source = folder + "/" + name, target = home + "/" + name
            guard !manager.fileExists(atPath: target), manager.fileExists(atPath: source),
                  (try? manager.attributesOfItem(atPath: source)[.type] as? FileAttributeType) == .typeRegular else { continue }
            try? manager.copyItem(atPath: source, toPath: target)
        }
    }

    private func stopCore() {
        guard let process else { return }
        self.process = nil
        process.terminate()
        // Mihomo removes its routes and the TUN device as it exits; give it a moment.
        for _ in 0..<30 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func append(_ text: String) {
        partial += text
        var parts = partial.components(separatedBy: "\n")
        partial = parts.removeLast()
        lines += parts.filter { !$0.isEmpty }
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }
}

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lives as long as the daemon: launchd starts it on demand and it never returns from run().
let helper = Helper()
helper.run()
