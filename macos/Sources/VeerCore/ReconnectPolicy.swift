import Foundation

/// Which open connections a routing change makes worth reconnecting, and which are kept whatever
/// the change. An open connection keeps the route it was opened with until it closes, so a change
/// shows on new connections only; closing one moves it to the new route at once, at the price of
/// the app opening it again. Veer used to close every connection after a profile switch, a rule
/// change or a reload, which also cut SSH sessions, coding agents and downloads that had nothing to
/// do with it, and made every open page reconnect (TLS, DNS) at once.
///
/// Only connections the change is known to move are picked: through the group whose node changed,
/// to a host or address a changed rule matches, or through a node or group the new profile no
/// longer has. Interactive and long-lived ones are kept: they keep the old route until they end.
public enum ReconnectPolicy {
    /// What changed, as far as open connections are concerned.
    public enum Change: Sendable, Equatable {
        /// A select group now uses another node.
        case selection(group: String)
        /// Rules matching these lines (`DOMAIN-SUFFIX,x.com`, `IP-CIDR,1.2.3.0/24`) now send traffic to `target`.
        case rules([String], target: String?)
        /// A new profile: connections through any policy it no longer has.
        case profile(policies: Set<String>)
        /// Something whose effect on a connection Veer can't tell (a reload with other edits): none.
        case unknown

        /// For an undo or redo: whichever way the rule goes now, every matching connection moves.
        public var withoutTarget: Change {
            if case let .rules(lines, _) = self { return .rules(lines, target: nil) }
            return self
        }
    }

    /// Processes whose connections are never closed for a routing change: remote shells, file
    /// copies and coding agents, where a cut connection loses work.
    public static let keptProcesses: Set<String> = [
        "ssh", "sshd", "scp", "sftp", "mosh-client", "mosh-server", "rsync", "autossh",
        "claude", "codex", "Claude", "Codex", "cursor-agent", "aider",
    ]

    /// A connection that has carried this much is a download or a stream in progress.
    public static let transferBytes: Int64 = 16 << 20

    /// The ids to close, and how many affected connections were kept.
    public static func plan(_ change: Change, connections: [MihomoController.Connection]) -> (close: [String], kept: Int) {
        var close: [String] = [], kept = 0
        for connection in connections where affected(connection, by: change) {
            if isKept(connection) { kept += 1 } else { close.append(connection.id) }
        }
        return (close, kept)
    }

    public static func isKept(_ connection: MihomoController.Connection) -> Bool {
        if connection.upload + connection.download >= transferBytes { return true }
        let process = connection.metadata.process ?? ""
        let path = connection.metadata.processPath ?? ""
        let executable = path.isEmpty ? process : (path as NSString).lastPathComponent
        if keptProcesses.contains(executable) || keptProcesses.contains(process) { return true }
        // Claude Code and Codex run as Node scripts from their own packages.
        return path.contains("/@anthropic-ai/claude-code/") || path.contains("/@openai/codex/") || path.contains("/.claude/local/")
    }

    public static func affected(_ connection: MihomoController.Connection, by change: Change) -> Bool {
        switch change {
        case .selection(let group):
            return connection.chains.contains(group)
        case let .rules(lines, target):
            // Already where the rule now sends it: nothing to move.
            if let target, connection.chains.last == target { return false }
            let host = connection.metadata.host?.lowercased() ?? ""
            let address = connection.metadata.destinationIP ?? ""
            return lines.contains { line in
                if !host.isEmpty, HostMatch.matches(line, host: host) { return true }
                return !address.isEmpty && HostMatch.contains(line, address: address)
            }
        case .profile(let policies):
            return connection.chains.contains { !policies.contains($0) }
        case .unknown:
            return false
        }
    }
}

/// Host and address matching for the rule lines Veer writes itself (domain and CIDR rules).
public enum HostMatch {
    public static func matches(_ line: String, host: String) -> Bool {
        let parts = line.split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return false }
        let host = host.lowercased(), value = parts[1].lowercased()
        switch parts[0] {
        case "DOMAIN": return host == value
        case "DOMAIN-SUFFIX": return host == value || host.hasSuffix("." + value)
        case "DOMAIN-KEYWORD": return host.contains(value)
        default: return false
        }
    }

    /// Whether an `IP-CIDR` or `IP-CIDR6` line covers `address`.
    public static func contains(_ line: String, address: String) -> Bool {
        let parts = line.split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "IP-CIDR" || parts[0] == "IP-CIDR6" else { return false }
        let cidr = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard let network = bytes(cidr[0]), let host = bytes(address), network.count == host.count else { return false }
        let prefix = cidr.count == 2 ? Int(cidr[1]) ?? network.count * 8 : network.count * 8
        guard (0...network.count * 8).contains(prefix) else { return false }
        for bit in 0..<prefix {
            let byte = bit / 8, mask = UInt8(0x80 >> (bit % 8))
            if network[byte] & mask != host[byte] & mask { return false }
        }
        return true
    }

    static func bytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
