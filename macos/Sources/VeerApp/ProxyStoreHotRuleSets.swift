import Foundation
import VeerCore
import VeerProxy

/// Routes that take effect without a reload, through the core's hot rule sets (`HotRuleSets`).
extension ProxyStore {
    /// A root core's home is the helper's to write, so under TUN the rule sets go through it.
    func hotWriter(tun: Bool) -> HotRuleSetWriter { tun ? HelperRuleSetWriter() : LocalRuleSetWriter(home: paths.core) }

    /// The hot rule sets an edit's routes go into; nil when any part needs a full reload (a new
    /// group, a removal, a rule set, a rule type rule sets cannot hold, a policy without a set).
    func hotEntries(for edit: RoutingLayer.Edit) -> [(set: HotRuleSets.RuleSet, line: String)]? {
        guard let hot = hotSets else { return nil }
        // App rules sit below the hot rule sets: a route there would come before them now and after
        // them once the config is rebuilt (`AppRuleBlock`). Reload instead.
        if let id = activeProfileID, routingStore.load(id).appRules.contains(where: \.enabled) { return nil }
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

    /// Restores the files referenced by the config that stayed in use after a refused reload.
    func restoreHotFiles(using writer: HotRuleSetWriter) async {
        guard let hot = hotSets else { return }
        try? await writer.reset(hot)
        for set in hot.sets {
            if let lines = hotLines[set.name], !lines.isEmpty { try? await writer.write(lines, to: set) }
        }
    }

    /// In `coreConfigWork`, writes the routes into their rule sets, the newest winning over the same rule elsewhere,
    /// reloads only the sets that changed, and closes the connections the routes now send
    /// elsewhere. Anything going wrong falls back to a full reload.
    func applyHotNow(_ entries: [(set: HotRuleSets.RuleSet, line: String)], profile id: UUID) async throws -> Bool {
        let change = ReconnectPolicy.Change.rules(entries.map(\.line), target: entries.count == 1 ? entries[0].set.target : nil)
        guard id == activeProfileID, switchingTo == nil, isRunning else { return false }
        guard let controller, let hot = hotSets else { return try await reloadRunningCoreNow(profile: id, reconnect: change) }
        let ticket = generation
        let writer = hotWriter(tun: tunActive)
        let timeline = ChangeTimeline(kind: "hotRoute")
        defer { timeline.finish() }
        let updated = updatingHotLines(with: entries)
        let changedSets = hot.sets.filter { updated[$0.name] != hotLines[$0.name] }
        do {
            for set in changedSets {
                guard isRunning else { return false }
                try await writer.write(updated[set.name] ?? [], to: set)
                guard isRunning else { return false }
                try await controller.refreshRuleProvider(set.name)
            }
        } catch {
            for set in changedSets {
                guard isRunning else { return false }
                try? await writer.write(hotLines[set.name] ?? [], to: set)
                try? await controller.refreshRuleProvider(set.name)
            }
            return try await reloadRunningCoreNow(profile: id, reconnect: change)
        }
        guard isRunning else { return false }
        hotLines = updated
        guard ticket == generation else { return false }
        timeline.mark("ruleSets")
        // Only connections to the hosts and addresses the routes match, and not the kept ones.
        await reconnect(after: change)
        timeline.mark("reconnect")
        // Views and the Agent read the effective config: the route is part of it now.
        _ = try? await effectiveTextInBackground(of: id)
        return ticket == generation
    }

    private func updatingHotLines(with entries: [(set: HotRuleSets.RuleSet, line: String)]) -> [String: [String]] {
        var updated = hotLines
        for entry in entries {
            for (name, lines) in updated where name != entry.set.name && lines.contains(entry.line) {
                updated[name] = lines.filter { $0 != entry.line }
            }
            if !(updated[entry.set.name] ?? []).contains(entry.line) {
                updated[entry.set.name, default: []].append(entry.line)
            }
        }
        return updated
    }
}
