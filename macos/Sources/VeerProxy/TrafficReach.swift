import Foundation

/// Whether this Mac's traffic reaches the core. The exit can't say: it is checked through the core's
/// own port, so it looks right either way.
public enum TrafficReach: Equatable, Sendable {
    case stopped(proxyOnStart: Bool)
    case tun
    case systemProxy
    /// Running, with the remembered system proxy still on its way back.
    case systemProxyComing
    case bypassed

    public init(running: Bool, tunActive: Bool, systemProxyOn: Bool, systemProxyRemembered: Bool) {
        if !running {
            self = .stopped(proxyOnStart: systemProxyRemembered)
        } else if tunActive {
            self = .tun
        } else if systemProxyOn {
            self = .systemProxy
        } else {
            self = systemProxyRemembered ? .systemProxyComing : .bypassed
        }
    }
}
