import Foundation

/// The proxy engine as the iOS app sees it. The prototype's only implementation is
/// `MihomoInProcessCore`; keeping the app on this protocol is what lets the core be replaced
/// before anything is distributed (the GPL exception covers the prototype only).
///
/// The running core is driven over its external controller (`MihomoController` in VeerCore),
/// as on the Mac, except what the embedded controller refuses (PUT/PATCH /configs): the mode
/// and a full config reload go through this protocol.
public protocol ProxyCore: Sendable {
    /// Human-readable core version, e.g. "Mihomo v1.19.29".
    var version: String { get }
    /// Starts the core with `config` (a complete Mihomo YAML) and `home` as its data directory.
    /// Returns once the listeners and the external controller are up; throws the core's message.
    func start(home: URL, config: URL) throws
    /// Stops listeners and the tunnel. Safe to call when stopped.
    func stop()
    /// Switches the running core's mode ("rule", "global", "direct").
    func setMode(_ mode: String) throws
    /// Re-reads `config` and applies it to the running core; unchanged listeners stay up.
    func reload(config: URL) throws
    /// Parses `yaml` without starting anything. `nil` means valid, otherwise the core's message.
    func validate(yaml: Data) -> String?
}

public struct ProxyCoreError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
