// macOS only: it downloads and runs a separate Mihomo binary.
#if os(macOS)
import CryptoKit
import Foundation
import VeerCore

/// GitHub's answer about a release, as far as Veer needs it.
private struct ReleaseAnswer: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        let digest: String?
    }

    let tagName: String
    let assets: [Asset]
}

/// A Mihomo release that this Mac can run.
public struct CoreRelease: Equatable, Sendable {
    public let version: String
    public let asset: URL
    public let sha256: String
}

/// Replaces the bundled Mihomo with a newer official build, unmodified, from upstream's releases. Kept
/// beside Veer's other files, so the app's signature stays intact; the bundled one remains the way back.
/// Only for a core run as the user: the TUN helper runs only what is signed by Veer's own team.
public struct CoreUpdater: Sendable {
    public init(paths: VeerPaths) { self.paths = paths }

    public let paths: VeerPaths

    static let latest = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!
    static let assetPrefix = "https://github.com/MetaCubeX/mihomo/releases/download/"

    public var installed: URL { paths.root.appendingPathComponent("core-bin/mihomo") }
    public var hasInstalled: Bool { FileManager.default.isExecutableFile(atPath: installed.path) }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    /// The asset for `architecture` in GitHub's answer. Its name has no suffix: the others are for older
    /// Go or CPU levels. Needs a digest, as it will be run.
    static func parse(_ data: Data, architecture: String = CoreUpdater.architecture) throws -> CoreRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let answer = try? decoder.decode(ReleaseAnswer.self, from: data) else {
            throw EditorError(String(localized: "无法读取 Mihomo 的版本信息。"))
        }
        let name = "mihomo-darwin-\(architecture)-\(answer.tagName).gz"
        guard let asset = answer.assets.first(where: { $0.name == name }), asset.browserDownloadUrl.hasPrefix(assetPrefix),
              let url = URL(string: asset.browserDownloadUrl),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw EditorError(String(localized: "这个版本没有适合这台 Mac 的可校验内核文件。"))
        }
        return CoreRelease(version: answer.tagName, asset: url, sha256: String(digest.dropFirst("sha256:".count)))
    }

    /// Whether `candidate` is a later version than `current`, as "v1.19.33". Anything not in that form
    /// is not later, as it can't be told.
    public static func isNewer(_ candidate: String, than current: String?) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let numbers = text.drop { $0 == "v" }.split(separator: ".").map { Int($0) }
            return numbers.isEmpty || numbers.contains(nil) ? nil : numbers.compactMap(\.self)
        }
        guard let new = parts(candidate) else { return false }
        guard let current, let old = parts(current) else { return true }
        for index in 0..<max(new.count, old.count) {
            let (first, second) = (index < new.count ? new[index] : 0, index < old.count ? old[index] : 0)
            if first != second { return first > second }
        }
        return false
    }

    /// "v1.19.29" from `mihomo -v`, or nil if it won't run or says something else.
    public static func version(of binary: URL) async -> String? {
        guard let output = await run(binary, ["-v"]) else { return nil }
        return output.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("v") && $0.contains(".") }.map(String.init)
    }

    /// What `fetch` returns is checked against the digest, then has to run and report the expected
    /// version before it replaces anything, so a failure at any step leaves the current core in place.
    public func install(_ release: CoreRelease, fetch: @Sendable (URL) async throws -> Data) async throws {
        let manager = FileManager.default
        let folder = installed.deletingLastPathComponent()
        // What an install cut short by a crash left behind.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("work-") {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        let work = folder.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let data = try await fetch(release.asset)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            throw EditorError(String(localized: "下载的内核文件校验失败，没有安装。"))
        }
        let packed = work.appendingPathComponent("mihomo.gz")
        try data.write(to: packed)
        guard await Self.run(URL(fileURLWithPath: "/usr/bin/gunzip"), [packed.path]) != nil else {
            throw EditorError(String(localized: "无法解压下载的内核文件。"))
        }
        let binary = work.appendingPathComponent("mihomo")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard await Self.version(of: binary) == release.version else {
            throw EditorError(String(localized: "下载的内核无法在这台 Mac 上运行，没有安装。"))
        }
        if manager.fileExists(atPath: installed.path) {
            _ = try manager.replaceItemAt(installed, withItemAt: binary)
        } else {
            try manager.moveItem(at: binary, to: installed)
        }
    }

    public func remove() throws {
        if manager.fileExists(atPath: installed.path) { try manager.removeItem(at: installed) }
    }

    private var manager: FileManager { .default }

    /// Its output if it exited cleanly within the time. Standard output only, as gunzip and mihomo keep
    /// nothing useful in the other.
    private static func run(_ binary: URL, _ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let limit = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: limit)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            limit.cancel()
            return process.terminationStatus == 0 ? String(bytes: data, encoding: .utf8) ?? "" : nil
        }.value
    }

    /// Asks upstream for its latest release. Direct, then through the core if it can help, as with
    /// subscriptions: GitHub is out of reach from some networks.
    public static func latestRelease(proxyPort: Int?) async throws -> CoreRelease {
        try parse(try await download(latest, proxyPort: proxyPort))
    }

    public static func download(_ url: URL, proxyPort: Int?) async throws -> Data {
        do {
            // Not long, with another way to try: a network that barely reaches GitHub would use it all.
            return try await request(url, proxyPort: nil, limit: proxyPort == nil ? 300 : 60)
        } catch {
            guard let proxyPort else { throw error }
            return try await request(url, proxyPort: proxyPort, limit: 300)
        }
    }

    private static func request(_ url: URL, proxyPort: Int?, limit: TimeInterval) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = limit
        // An empty dictionary means no proxy at all, ignoring the system's.
        configuration.connectionProxyDictionary = proxyPort.map { port in
            [kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: port,
             kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: port]
        } ?? [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Veer", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request) else {
            throw EditorError(String(localized: "连不上 GitHub，请稍后再试，或启动内核后再试。"))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EditorError(String(localized: "GitHub 没有返回内核信息，请稍后再试。"))
        }
        return data
    }
}
#endif
