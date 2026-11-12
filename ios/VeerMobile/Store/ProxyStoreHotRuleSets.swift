import Foundation
import VeerProxy

/// Routes that take effect without a reload, through the core's hot rule sets (`HotRuleSets`).
/// Lifted from the Mac (macos/Sources/VeerApp/ProxyStoreHotRuleSets.swift); the iPhone has no
/// root helper, so the app writes the sets into the core's home itself.
extension ProxyStore {
    func hotWriter() -> HotRuleSetWriter { LocalRuleSetWriter(home: paths.core) }

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
        await enqueueHot(entries, profile: id)?.value
    }

    /// Capture identity and FIFO order at the edit, before any unstructured task can be delayed.
    @discardableResult
    func enqueueHot(_ entries: [(set: HotRuleSets.RuleSet, line: String)], profile id: UUID) -> Task<Void, Never>? {
        guard let token = runtimeLifecycle.current, token.profileID == id, isCurrent(token), isRunning else { return nil }
        return runtimeLifecycle.enqueue { [self] in
            await applyHotNow(entries, token: token)
        }
    }

    private func applyHotNow(_ entries: [(set: HotRuleSets.RuleSet, line: String)], token: CoreLifecycle.Token) async {
        guard isCurrent(token), isRunning else { return }
        guard let controller, let hot = hotSets else {
            return await reloadCore(token, closingConnections: true)
        }
        // A preceding reload may have rebuilt/reordered the sets. Never write an old numeric
        // provider name into a different policy's file; resolve its target against this build.
        var resolved: [(set: HotRuleSets.RuleSet, line: String)] = []
        for entry in entries {
            guard let set = hot.set(for: entry.set.target) else {
                return await reloadCore(token, closingConnections: true)
            }
            resolved.append((set, entry.line))
        }
        var linesBySet = hotLines
        var changed = Set<String>()
        for entry in resolved {
            for (name, lines) in linesBySet where name != entry.set.name && lines.contains(entry.line) {
                linesBySet[name] = lines.filter { $0 != entry.line }
                changed.insert(name)
            }
            if !(linesBySet[entry.set.name] ?? []).contains(entry.line) {
                linesBySet[entry.set.name, default: []].append(entry.line)
                changed.insert(entry.set.name)
            }
        }
        do {
            for set in hot.sets where changed.contains(set.name) {
                guard isCurrent(token) else { return }
                try await hotWriter().write(linesBySet[set.name] ?? [], to: set)
                guard isCurrent(token) else { return }
                try await controller.refreshRuleProvider(set.name)
                guard isCurrent(token) else { return }
            }
        } catch {
            guard isCurrent(token) else { return }
            return await reloadCore(token, closingConnections: true)
        }
        guard isCurrent(token) else { return }
        hotLines = linesBySet
        if reconnectAfterChanges, let list = try? await controller.connections() {
            guard isCurrent(token) else { return }
            let lines = resolved.map(\.line)
            for connection in list {
                guard isCurrent(token) else { return }
                let host = connection.metadata.host.flatMap { $0.isEmpty ? nil : $0 } ?? connection.metadata.destinationIP ?? ""
                // An address rule has no host to compare; such a route closes every connection.
                if lines.contains(where: { HotRuleSets.matches($0, host: host) || $0.hasPrefix("IP-CIDR") }) {
                    try? await controller.closeConnection(connection.id)
                }
            }
        }
        guard isCurrent(token) else { return }
        // Views and the Agent read the effective config: the route is part of it now.
        _ = try? await effectiveTextInBackground(of: token.profileID)
    }
}
