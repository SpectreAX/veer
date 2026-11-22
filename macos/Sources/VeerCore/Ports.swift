import Darwin

/// Local TCP ports.
public enum Ports {
    /// Ports picked for the core, below the system's ephemeral range (49152 and up on macOS).
    /// The kernel never hands these out to a socket that asks for any port, so an outgoing
    /// connection or a new listener elsewhere can't take one in the moment between picking it and
    /// the core binding it. A port from the ephemeral range could be taken in that moment: the
    /// kernel gives a just-released port to the next socket, and the core then started without a
    /// controller and waited out its readiness limit.
    public static let reserved = 20000...39999

    /// A port nothing is bound to now, chosen at random from `reserved`; from the ephemeral range
    /// only when none of a few dozen tries there is free.
    public static func free() -> Int? {
        for _ in 0..<64 {
            let port = Int.random(in: reserved)
            if bindable(port) { return port }
        }
        return ephemeral()
    }

    /// Whether a socket could bind `port` on 127.0.0.1 now.
    static func bindable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Whether a Mihomo log says it could not listen on `port` because another program holds it.
    /// Mihomo keeps running without that listener, so its log is the only sign. Only the bind
    /// error for this exact port counts: provider errors and other ports do not.
    public static func listenFailed<Line: StringProtocol>(on port: Int, in log: some Sequence<Line>) -> Bool {
        log.contains { $0.contains("bind: address already in use") && $0.contains(":\(port): bind") }
    }

    /// A port nothing listens on now, from the system's ephemeral range.
    static func ephemeral() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// Whether something already listens on `port` on this Mac.
    public static func inUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
