import Foundation
import Yams

/// The last step before the in-process core reads a runtime config: whatever the profile says,
/// nothing listens beyond 127.0.0.1 and no TUN device opens.
///
/// `RuntimeConfig.build` (VeerProxy) already writes Veer's ports, `allow-lan: false` and a loopback
/// controller, and drops `tun` and the extra listener ports. A profile may still carry Mihomo's
/// `listeners` and `tunnels` (each with its own listen address), a DNS listener or a TLS / Unix
/// controller; the Mac leaves those to the user, the prototype removes them, because the core runs
/// inside the app and must never be reachable from the network.
public enum LoopbackRuntime {
    /// Top-level keys that open another way in, pick an interface, or start TUN.
    static let removed = [
        "listeners", "tunnels", "tun", "port", "socks-port", "redir-port", "tproxy-port", "external-controller-tls",
        "external-controller-unix", "external-controller-pipe", "external-controller-cors", "external-ui", "external-ui-url",
        "external-ui-name", "external-doh-server", "interface-name", "routing-mark", "iptables", "ebpf", "auto-redirect",
    ]

    public static func harden(_ yaml: String) throws -> String {
        guard case .mapping(var mapping)? = try Yams.compose(yaml: yaml) else {
            throw ProxyCoreError(message: "runtime config is not a mapping")
        }
        for key in removed { mapping[Node(key)] = nil }
        guard let controller = mapping[Node("external-controller")]?.string, controller.hasPrefix("127.0.0.1:") else {
            throw ProxyCoreError(message: "runtime config has no loopback external-controller")
        }
        mapping[Node("allow-lan")] = Node("false", Tag(.bool))
        mapping[Node("bind-address")] = Node("127.0.0.1")
        mapping[Node("tun")] = Node([(Node("enable"), Node("false", Tag(.bool)))])
        if case .mapping(var dns)? = mapping[Node("dns")] {
            dns[Node("listen")] = nil
            mapping[Node("dns")] = .mapping(dns)
        }
        return try Yams.serialize(node: .mapping(mapping), allowUnicode: true)
    }
}
