import Darwin
import Foundation

/// Asks a core that has just started whether it carries traffic yet. Its controller answers and
/// its port accepts connections within a few hundredths of a second, but until it has read every
/// rule set and node list it drops whatever comes in: with a slow or unreachable link and nothing
/// cached, that lasted 10 to 16 seconds in measurements, during which the system proxy would
/// have pointed every app at a port that refuses them.
///
/// The probe opens a tunnel through the proxy port to the core's own controller and sends
/// nothing. A core that is still loading closes it within a millisecond; one that is running
/// keeps it open while it connects. A rule that rejects local addresses looks the same as
/// loading, which is why the caller also asks the controller (`providersLoaded`).
public enum TunnelProbe {
    public enum Answer: Sendable, Equatable {
        /// The core kept the tunnel open: traffic gets through it.
        case carried
        /// The core closed it at once: still loading, or a rule rejects it.
        case dropped
        /// Nothing listens on the proxy port, or it did not answer as a proxy.
        case noProxy
    }

    /// How long a tunnel has to stay open to count. Measured closes took 0.1 to 1.1 ms.
    public static let patience = Duration.milliseconds(20)

    /// Blocks for up to `patience`, so call it off the main thread.
    public static func ask(proxyPort: Int, controllerPort: Int, patience: Duration = TunnelProbe.patience) -> Answer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noProxy }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: in_port_t(UInt16(clamping: proxyPort).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { return .noProxy }
        let request = Array("CONNECT 127.0.0.1:\(controllerPort) HTTP/1.1\r\nHost: 127.0.0.1:\(controllerPort)\r\n\r\n".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return .noProxy }
        // The proxy's own answer, before the core decides what to do with the tunnel.
        guard readable(fd, within: .milliseconds(500)) else { return .noProxy }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return .dropped }
        guard String(bytes: buffer.prefix(count), encoding: .utf8)?.contains(" 200 ") == true else { return .noProxy }
        // Nothing is sent through it, so the only thing to read is the core closing it.
        return readable(fd, within: patience) ? .dropped : .carried
    }

    private static func readable(_ fd: Int32, within duration: Duration) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(StartupTimeline.milliseconds(duration))) > 0
    }
}
