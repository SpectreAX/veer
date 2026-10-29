import Foundation

/// What Veer was doing when it last quit, so the next launch can pick it up again, and the
/// proxy settings it replaced, so they can be put back even after a crash.
public struct ProxyState: Codable, Sendable, Equatable {
    /// The core was running.
    public var running = false
    /// `rule`, `global` or `direct`.
    public var mode: String?
    /// Veer had the system proxy pointing at it.
    public var systemProxy = false
    /// The port the system proxy pointed at.
    public var proxyPort: Int?
    /// The settings in place before Veer's; nil while Veer's proxy is off.
    public var snapshot: ProxySnapshot?

    public init() {}
}

/// `state.json`, written whenever the state changes.
public final class StateStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(paths: VeerPaths) { url = paths.state }

    public func load() -> ProxyState {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return ProxyState() }
            return (try? JSONDecoder().decode(ProxyState.self, from: data)) ?? ProxyState()
        }
    }

    public func save(_ state: ProxyState) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(state).write(to: url, options: .atomic)
        }
    }
}
