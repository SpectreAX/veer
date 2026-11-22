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

    /// Tests a group's members, its button showing the run.
    func testDelay(_ group: String) {
        guard let found = groups.first(where: { $0.name == group }) else { return }
        testNodes(testableMembers(of: found), scope: .group(group))
    }

    /// Every node and group once, after a start or a profile switch: nodes first, as groups
    /// answer through one of them.
    func testEverythingOnce() {
        var nodes: [String] = [], nested: [String] = []
        for group in groups {
            for member in group.members where !Self.untestable.contains(member.name) {
                if member.isGroup { nested.append(member.name) } else { nodes.append(member.name) }
            }
        }
        testNodes(nodes + nested, scope: .everything)
    }

    /// Starts a run of `names` under `scope` (a group, a region, or every group). A run already under
    /// way for the scope goes on; one for another scope runs beside it. Each result lands only if
    /// the profile it was measured in is still the one running.
    func testNodes(_ names: [String], scope: LatencyScope) {
        guard isRunning, switchingTo == nil, let controller, !names.isEmpty, latencyRuns[scope] == nil else { return }
        let started = generation
        testingScopes.insert(scope)
        for name in names where delays[name] != .testing { delays[name] = .testing }
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
        delays[name] = state
        if state.isResult { delayTimes[name] = .now }
        flushDelays()
    }

    /// Results reach the groups a few times a second, not once per node: every tile would
    /// otherwise draw again for each of several hundred results.
    func flushDelays(now: Bool = false) {
        if now {
            delayFlush?.cancel()
            delayFlush = nil
            groups = groups.map(applyingDelays)
            return
        }
        guard delayFlush == nil else { return }
        delayFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            delayFlush = nil
            groups = groups.map(applyingDelays)
        }
    }

    private func applyingDelays(_ group: Group) -> Group {
        Group(name: group.name, type: group.type, now: group.now, members: group.members.map { member in
            guard let state = delays[member.name], state != member.state else { return member }
            return Group.Member(name: member.name, delay: member.delay, isGroup: member.isGroup, state: state)
        })
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
        for member in stale { delays[member] = .testing }
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
