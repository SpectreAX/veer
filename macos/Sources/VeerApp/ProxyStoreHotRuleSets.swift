import Foundation
import VeerProxy

/// Routes that take effect without a reload, through the core's hot rule sets (`HotRuleSets`).
extension ProxyStore {
    /// A root core's home is the helper's to write, so under TUN the rule sets go through it.
    func hotWriter(tun: Bool) -> HotRuleSetWriter { tun ? HelperRuleSetWriter() : LocalRuleSetWriter(home: paths.core) }

    /// The hot rule sets an edit's routes go into; nil when any part needs a full reload (a new
    /// group, a removal, a rule set, a rule type rule sets cannot hold, a policy without a set).
    func hotEntries(for edit: RoutingLayer.Edit) -> [(set: HotRuleSets.RuleSet, line: String)]? {
        guard let hot = hotSets else { return nil }
        let items = edit.items.filter { edit.accepted.contains($0.id) }
        guard !items.isEmpty else { return nil }
        var entries: [(set: HotRuleSets.RuleSet, line: String)] = []
        for item in items {
            guard item.kind == .route, let target = item.targetName, let set = hot.set(for: target),
                  let line = HotRuleSets.line(matchType: item.matchType, match: item.match) else { return nil }
            entries.append((set, line))
        }
        return entries
    }

    /// Writes the routes into their rule sets, the newest winning over the same rule elsewhere,
    /// reloads only the sets that changed, and closes the connections the routes now send
    /// elsewhere. Anything going wrong falls back to a full reload.
    func applyHot(_ entries: [(set: HotRuleSets.RuleSet, line: String)], profile id: UUID) async {
        guard let controller, let hot = hotSets else { return await reloadRunningCore(closingConnections: true) }
        var changed = Set<String>()
        for entry in entries {
            for (name, lines) in hotLines where name != entry.set.name && lines.contains(entry.line) {
                hotLines[name] = lines.filter { $0 != entry.line }
                changed.insert(name)
            }
            if !(hotLines[entry.set.name] ?? []).contains(entry.line) {
                hotLines[entry.set.name, default: []].append(entry.line)
                changed.insert(entry.set.name)
            }
        }
        do {
            for set in hot.sets where changed.contains(set.name) {
                try await hotWriter(tun: tunActive).write(hotLines[set.name] ?? [], to: set)
                try await controller.refreshRuleProvider(set.name)
            }
        } catch {
            return await reloadRunningCore(closingConnections: true)
        }
        if reconnectAfterChanges, let list = try? await controller.connections() {
            let lines = entries.map(\.line)
            for connection in list {
                let host = connection.metadata.host.flatMap { $0.isEmpty ? nil : $0 } ?? connection.metadata.destinationIP ?? ""
                // An address rule has no host to compare; such a route closes every connection.
                if lines.contains(where: { HotRuleSets.matches($0, host: host) || $0.hasPrefix("IP-CIDR") }) {
                    try? await controller.closeConnection(connection.id)
                }
            }
        }
        // Views and the Agent read the effective config: the route is part of it now.
        _ = try? await effectiveTextInBackground(of: id)
    }
}
