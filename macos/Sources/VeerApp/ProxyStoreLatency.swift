import Foundation
import os
import VeerCore
import VeerProxy

/// A profile can give a group any name, including the text Veer uses to identify a region.
nonisolated enum LatencyScope: Hashable, Sendable {
    case everything
    case group(String)
    case region(String)
}

/// One node's latest result in the running profile, nil before Veer has one; a view shows its own
/// member's state then, as each group reported it. The store keeps one per name
/// (`delayCell(for:)`), so a result redraws the views that show that node, and nothing else.
@Observable final class NodeDelayCell {
    var result: NodeDelay?
    init(_ result: NodeDelay?) { self.result = result }
}

/// The one delay-testing service: the Proxies page, the map's regions, the start-up test and the
/// Agent's runtime actions all test through here (`LatencyTest`), a few nodes at a time, with every
/// result tagged by the profile it was measured in.
extension ProxyStore {
    /// Policies that block traffic: a delay test means nothing for them.
    static let untestable: Set<String> = ["REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    /// What can be tested in a group: its members, less the blocking policies.
    func testableMembers(of group: Group) -> [String] {
        group.members.map(\.name).filter { !Self.untestable.contains($0) }
    }

    /// Whether a test under `scope` can start now: the core runs, no profile switch is under way (its
    /// results would belong to the profile being replaced) and the scope is not already testing.
    /// The buttons that start one are disabled otherwise, rather than doing nothing.
    func canStartLatencyTest(_ scope: LatencyScope) -> Bool {
        isRunning && switchingTo == nil && latencyRuns[scope] == nil && !testingScopes.contains(scope)
    }

    /// Tests a group's members, its button showing the run.
    func testDelay(_ group: String) {
        guard let found = groups.first(where: { $0.name == group }) else { return }
        testNodes(testableMembers(of: found), scope: .group(group))
    }

    /// Every node and group once, after a start or a profile switch: nodes first, as groups
    /// answer through one of them.
    func testEverythingOnce() {
        testNodes(Self.everythingToTest(in: groups), scope: .everything)
    }

    /// Each node and group in `groups` once, nodes first: a node in several groups is tested once.
    static func everythingToTest(in groups: [Group]) -> [String] {
        var nodes: [String] = [], nested: [String] = [], seen: Set<String> = []
        for group in groups {
            for member in group.members where !untestable.contains(member.name) && seen.insert(member.name).inserted {
                if member.isGroup { nested.append(member.name) } else { nodes.append(member.name) }
            }
        }
        return nodes + nested
    }

    /// Starts a run of `names` under `scope` (a group, a region, or every group). A run already under
    /// way for the scope goes on; one for another scope runs beside it. Each result lands only if
    /// the profile it was measured in is still the one running.
    func testNodes(_ names: [String], scope: LatencyScope) {
        guard canStartLatencyTest(scope), let controller, !names.isEmpty else { return }
        let started = generation
        testingScopes.insert(scope)
        for name in names where delays[name] != .testing { setDelay(.testing, for: name) }
        flushDelays()
        let url = delayURL
        let test = LatencyTest { name in try await controller.testDelay(proxy: name, url: url) }
        latencyRuns[scope] = Task { [weak self] in
            await test.run(names) { name, state in
                await MainActor.run { self?.record(state, for: name, generation: started) }
            }
            guard let self else { return }
            // Not for a newer generation: its own run may have the scope by now.
            guard started == generation else { return }
            latencyRuns[scope] = nil
            testingScopes.remove(scope)
            flushDelays(now: true)
            checkTestedNodes()
        }
    }

    /// A result, unless it belongs to a profile that has since been replaced.
    func record(_ state: NodeDelay, for name: String, generation measured: Int) {
        guard measured == generation else { return }
        // Called off while another scope still tests it: that run will say.
        if state == .cancelled, latencyRuns.count > 1 { return }
        setDelay(state, for: name)
        if state.isResult { delayTimes[name] = .now }
        flushDelays()
    }

    /// A node's delay, shown at the next flush.
    func setDelay(_ state: NodeDelay, for name: String) {
        delays[name] = state
        pendingDelayNames.insert(name)
    }

    /// The cell that holds a node's latest result.
    func delayCell(for name: String) -> NodeDelayCell {
        if let cell = delayCells[name] { return cell }
        let cell = NodeDelayCell(delays[name])
        delayCells[name] = cell
        return cell
    }

    /// `delays`, read so that a view follows each flush of results (`delayRevision`) rather than
    /// each result.
    var latestDelays: [String: NodeDelay] {
        _ = delayRevision
        return delays
    }

    /// A member's delay now: the latest result, else what its group last said. Read as a menu is
    /// made, without observing anything.
    func delayState(for member: Group.Member) -> NodeDelay { delays[member.name] ?? member.state }

    /// Results reach the cells a few times a second, not once per node, and only the cells of the
    /// nodes that changed. The groups themselves take them once, when a run ends (`now`): a new
    /// `groups` redraws every group, its menu and its tiles, which several times a second made the
    /// page stutter with a few thousand members.
    func flushDelays(now: Bool = false) {
        if now {
            delayFlush?.cancel()
            delayFlush = nil
            applyPendingDelays()
            var changed = false
            let synced = groups.map { group in
                let applied = applyingDelays(group)
                if applied != group { changed = true }
                return applied
            }
            if changed { groups = synced }
            return
        }
        guard delayFlush == nil else { return }
        delayFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            delayFlush = nil
            applyPendingDelays()
        }
    }

    private func applyPendingDelays() {
        guard !pendingDelayNames.isEmpty else { return }
        for name in pendingDelayNames {
            if let cell = delayCells[name], cell.result != delays[name] { cell.result = delays[name] }
        }
        pendingDelayNames = []
        delayRevision += 1
    }

    private func applyingDelays(_ group: Group) -> Group {
        guard group.members.contains(where: { member in delays[member.name].map { $0 != member.state } ?? false }) else { return group }
        return Group(name: group.name, type: group.type, now: group.now, members: group.members.map { member in
            guard let state = delays[member.name], state != member.state else { return member }
            return Group.Member(name: member.name, delay: member.delay, isGroup: member.isGroup, state: state)
        })
    }

    /// The cells after the groups are read again or the results are forgotten. Cells of nodes no
    /// group lists any more are let go.
    func syncDelayCells() {
        let listed = Set(groups.flatMap { $0.members.map(\.name) })
        for (name, cell) in delayCells {
            guard listed.contains(name) else { delayCells[name] = nil; continue }
            if cell.result != delays[name] { cell.result = delays[name] }
        }
    }

    /// Reads each new node's name once off the main thread (region, notice), so the first draw
    /// of a big subscription finds the answers already made.
    func warmNodeLookups(_ names: Set<String>) {
        let fresh = names.subtracting(warmedNodeNames)
        guard !fresh.isEmpty else { return }
        if warmedNodeNames.count > 20_000 { warmedNodeNames = [] }
        warmedNodeNames.formUnion(fresh)
        Task.detached(priority: .utility) {
            for name in fresh {
                _ = NodeLocator.locate(name)
                _ = NodeCleanup.isInfoNode(name)
            }
        }
    }

    /// Calls off every run and forgets every result: the profile they measured is gone.
    func resetDelays() {
        generation += 1
        for run in latencyRuns.values { run.cancel() }
        latencyRuns = [:]
        testingScopes = []
        delays = [:]
        delayTimes = [:]
        delayFlush?.cancel()
        delayFlush = nil
        pendingDelayNames = []
        // Back to what the groups say until they are read again.
        for cell in delayCells.values where cell.result != nil { cell.result = nil }
        delayRevision += 1
    }

    /// The members' delays for a choice such as "the fastest": results measured in the last
    /// `LatencyTest.freshFor` seconds are used as they are, and only the rest are tested. Groups
    /// that choose by delay themselves (URL-Test) are not taken as having tested anything.
    func delaysForChoice(in name: String, reuseFresh: Bool = true) async throws -> [String: NodeDelay] {
        guard switchingTo == nil else { throw EditorError(String(localized: "配置已经切换，测速结果作废。")) }
        let controller = try runningController()
        let started = generation
        let group = try await knownGroup(name)
        guard started == generation else { throw EditorError(String(localized: "配置已经切换，测速结果作废。")) }
        let names = testableMembers(of: group)
        var result: [String: NodeDelay] = [:]
        var stale: [String] = []
        for member in names {
            if reuseFresh, let state = delays[member], state.isResult, let at = delayTimes[member], Date.now.timeIntervalSince(at) < LatencyTest.freshFor {
                result[member] = state
            } else {
                stale.append(member)
            }
        }
        guard !stale.isEmpty else { return result }
        let scope = LatencyScope.group(name)
        testingScopes.insert(scope)
        defer { if started == generation { testingScopes.remove(scope) } }
        let before = stale.reduce(into: [String: NodeDelay]()) { $0[$1] = delays[$1] ?? .untested }
        for member in stale { setDelay(.testing, for: member) }
        flushDelays()
        let url = delayURL
        var test = LatencyTest(concurrency: reuseFresh ? 16 : LatencyTest.defaultConcurrency, maximumConcurrency: reuseFresh ? 32 : nil,
                               retriesFailures: !reuseFresh) { node in
            try await controller.testDelay(proxy: node, url: url, timeout: reuseFresh ? 2500 : 5000)
        }
        test.stopsWhenNoneCanBeatBest = reuseFresh
        let measured = await test.run(stale) { node, state in
            // Cut short because it could not win: it keeps what it showed before.
            await MainActor.run { self.record(state == .cancelled ? before[node] ?? .untested : state, for: node, generation: started) }
        }
        guard started == generation else { throw EditorError(String(localized: "配置已经切换，测速结果作废。")) }
        flushDelays(now: true)
        return result.merging(measured) { $1 }
    }

    /// Tests every member now; 0 is a timeout or failure, as the Agent's results read.
    func testNow(_ name: String, reuseFresh: Bool = false) async throws -> [String: Int] {
        try await delaysForChoice(in: name, reuseFresh: reuseFresh).compactMapValues(\.legacyDelay)
    }
}

/// The steps of one routing change with their times, in the system log and as signposts
/// (`com.yamax.veer` / `Change`), names and durations only: no hosts, rules or secrets.
final class ChangeTimeline {
    private static let signposter = OSSignposter(subsystem: "com.yamax.veer", category: "Change")
    private static let log = Logger(subsystem: "com.yamax.veer", category: "Change")
    let kind: String
    private let began = ContinuousClock.now
    private var last = ContinuousClock.now
    private(set) var steps: [(String, Duration)] = []
    private let state: OSSignpostIntervalState

    init(kind: String) {
        self.kind = kind
        state = Self.signposter.beginInterval("Change", "\(kind, privacy: .public)")
    }

    func mark(_ step: String) {
        let now = ContinuousClock.now
        steps.append((step, now - last))
        last = now
        Self.signposter.emitEvent("Step", "\(step, privacy: .public)")
    }

    func finish() {
        Self.signposter.endInterval("Change", state)
        let total = ContinuousClock.now - began
        let text = steps.map { "\($0.0) \(Self.ms($0.1))" }.joined(separator: ", ")
        Self.log.info("\(self.kind, privacy: .public) \(Self.ms(total), privacy: .public): \(text, privacy: .public)")
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
