import Foundation
// Internal: the C module stays out of this module's interface, so the app and its tests import
// VeerMobileKit without needing the core's headers.
internal import MihomoCore

/// Mihomo linked into the app (ios/core, a cgo c-archive). The Go side owns all state; calls are
/// serialised here so Start/Stop never overlap. Strings returned by the core are malloc'd and
/// released with `VeerCoreFree`.
public final class MihomoInProcessCore: ProxyCore, @unchecked Sendable {
    public static let shared = MihomoInProcessCore()

    private let lock = NSLock()

    private init() {}

    public var version: String {
        Self.take(VeerCoreVersion()) ?? "Mihomo"
    }

    public func start(home: URL, config: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let error = home.path.withCString { homePath in
            config.path.withCString { configPath in
                Self.take(VeerCoreStart(UnsafeMutablePointer(mutating: homePath), UnsafeMutablePointer(mutating: configPath)))
            }
        }
        if let error { throw ProxyCoreError(message: error) }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        VeerCoreStop()
    }

    public func setMode(_ mode: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = mode.withCString({ Self.take(VeerCoreSetMode(UnsafeMutablePointer(mutating: $0))) }) {
            throw ProxyCoreError(message: error)
        }
    }

    public func reload(config: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = config.path.withCString({ Self.take(VeerCoreReload(UnsafeMutablePointer(mutating: $0))) }) {
            throw ProxyCoreError(message: error)
        }
    }

    public func validate(yaml: Data) -> String? {
        let text = String(decoding: yaml, as: UTF8.self)
        return text.withCString { Self.take(VeerCoreValidate(UnsafeMutablePointer(mutating: $0))) }
    }

    /// Copies a core-owned C string into Swift and frees it.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { VeerCoreFree(pointer) }
        return String(cString: pointer)
    }
}
