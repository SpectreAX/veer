import Foundation
import Testing
@testable import VeerCore

/// The delay-test runner: bounded, retrying, cancellable, and honest about what it did not test.
struct LatencyTestTests {
    /// Counts tests in flight.
    actor Gauge {
        var now = 0, most = 0, calls: [String] = []
        func enter(_ name: String) { now += 1; most = max(most, now); calls.append(name) }
        func leave() { now -= 1 }
    }

    actor Reports {
        var items: [(String, NodeDelay)] = []
        func add(_ name: String, _ state: NodeDelay) { items.append((name, state)) }
    }

    @Test func neverRunsMoreThanItsWidthAndTestsEachNameOnce() async {
        let gauge = Gauge()
        let test = LatencyTest(concurrency: 3, maximumConcurrency: 3) { name in
            await gauge.enter(name)
            try await Task.sleep(for: .milliseconds(5))
            await gauge.leave()
            return .delay(40)
        }
        let names = (0..<30).map { "N\($0)" } + ["N1", "N2"]
        let results = await test.run(names) { _, _ in }
        #expect(await gauge.most <= 3)
        #expect(await gauge.calls.count == 30, "duplicates are tested once")
        #expect(results.count == 30 && results.values.allSatisfy { $0 == .measured(40) })
    }

    @Test func widensOnSuccessAndNarrowsOnFailure() async {
        let gauge = Gauge()
        let test = LatencyTest(concurrency: 2, maximumConcurrency: 6) { name in
            await gauge.enter(name)
            try await Task.sleep(for: .milliseconds(3))
            await gauge.leave()
            return .delay(10)
        }
        _ = await test.run((0..<80).map { "N\($0)" }) { _, _ in }
        let most = await gauge.most
        #expect(most > 2 && most <= 6)
    }

    @Test func failuresGetOneMoreTryAndARealTimeoutStaysATimeout() async {
        let tries = Gauge()
        let test = LatencyTest(concurrency: 4) { name in
            await tries.enter(name)
            if name == "dead" { return .timedOut }
            // Fails the first time only, as a dropped DNS lookup does.
            if name == "flaky", await tries.calls.filter({ $0 == "flaky" }).count == 1 { return .failed("dial tcp: lookup flaky.test: no such host") }
            return .delay(80)
        }
        let results = await test.run(["ok", "flaky", "dead"]) { _, _ in }
        #expect(results["ok"] == .measured(80))
        #expect(results["flaky"] == .measured(80))
        #expect(results["dead"] == .timedOut)
        #expect(await tries.calls.filter { $0 == "dead" }.count == 2)
    }

    @Test func aCancelledRunStopsAndReportsTheRestAsCancelled() async {
        let gauge = Gauge(), reports = Reports()
        let test = LatencyTest(concurrency: 2, maximumConcurrency: 2) { name in
            await gauge.enter(name)
            try await Task.sleep(for: .seconds(5))
            return .delay(1)
        }
        let task = Task { await test.run((0..<20).map { "N\($0)" }) { await reports.add($0, $1) } }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let results = await task.value
        #expect(await gauge.calls.count == 2, "nothing more starts once cancelled")
        #expect(results.values.allSatisfy { $0 == .cancelled })
        #expect(await reports.items.allSatisfy { $0.1 == .cancelled })
    }

    /// What each probe got to: its own outcome, or cancellation before it.
    actor Outcomes {
        var finished: [String] = [], cancelled: Set<String> = []
        func finish(_ name: String) { finished.append(name) }
        func cancel(_ name: String) { cancelled.insert(name) }
    }

    /// Hands out one answer: the first to claim it wins.
    actor Once {
        var taken = false
        func claim() -> Bool { defer { taken = true }; return !taken }
    }

    /// Runs `body`, giving up after `limit` without waiting for it: a run that fails to stop ends
    /// the test there instead of hanging it, even if it ignores cancellation. Nil when the limit
    /// came first.
    static func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let work = Task {
                let value = await body()
                if await once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if await once.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Judged by what happened, not by the clock: the slow probes would each reach an outcome of
    /// their own after 2 s, so a runner that waits for them fails here (they finish, or show as
    /// measured and timed out) rather than on a busy machine's scheduling. It once failed at 321 ms
    /// against a 300 ms limit with every result right.
    @Test func aChoiceStopsOnceNoRunningTestCanBeatTheBest() async throws {
        let outcomes = Outcomes(), reports = Reports()
        var test = LatencyTest(concurrency: 8, retriesFailures: false) { name in
            do {
                if name == "fast" {
                    try await Task.sleep(for: .milliseconds(10))
                    await outcomes.finish(name)
                    return .delay(10)
                }
                try await Task.sleep(for: .seconds(2))
                await outcomes.finish(name)
                return name.hasPrefix("hole") ? .timedOut : .delay(400)
            } catch {
                await outcomes.cancel(name)
                throw error
            }
        }
        test.stopsWhenNoneCanBeatBest = true
        let probe = test
        let results = try #require(await Self.within(.seconds(10)) {
            await probe.run(["fast", "slow", "hole1", "hole2"]) { await reports.add($0, $1) }
        }, "the run neither stopped early nor finished within its bound")
        #expect(results["fast"] == .measured(10))
        #expect(results["slow"] == .cancelled && results["hole1"] == .cancelled && results["hole2"] == .cancelled)
        #expect(await outcomes.finished == ["fast"], "only the fast probe reached its own outcome")
        #expect(await outcomes.cancelled == ["slow", "hole1", "hole2"], "the rest were cancelled while still running")
        let reported = await reports.items
        #expect(reported.first { $0.0 == "fast" }?.1 == .measured(10))
        #expect(reported.filter { $0.0 != "fast" }.allSatisfy { $0.1 == .cancelled })
    }

    @Test func theLastBatchCanStopWithoutAnotherProbeFinishing() async {
        var test = LatencyTest(concurrency: 1, maximumConcurrency: 1, retriesFailures: false) { name in
            if name == "first" { return .delay(100) }
            // The last probe starts after `first` replies. Its budget hasn't elapsed on that reply,
            // and the runner has to wake up on its own before the slow probe finishes.
            try await Task.sleep(for: .seconds(1))
            return .delay(1000)
        }
        test.stopsWhenNoneCanBeatBest = true
        let results = await test.run(["first", "last"]) { _, _ in }
        #expect(results["first"] == .measured(100))
        #expect(results["last"] == .cancelled)
    }

    @Test func aControllerThatStopsAnsweringIsNotReportedAsTimeouts() async {
        let test = LatencyTest(concurrency: 1) { name in
            if name == "B" { throw EditorError("controller gone") }
            return .delay(30)
        }
        let results = await test.run(["A", "B", "C", "D"]) { _, _ in }
        #expect(results["A"] == .measured(30))
        #expect(results["B"] == .coreNotReady && results["C"] == .coreNotReady && results["D"] == .coreNotReady)
    }

    @Test func historyAndLegacyDelaysMapBothWays() {
        #expect(NodeDelay(history: nil) == .untested)
        #expect(NodeDelay(history: 0) == .timedOut)
        #expect(NodeDelay(history: 120) == .measured(120))
        #expect(NodeDelay.failed("x").legacyDelay == 0 && NodeDelay.testing.legacyDelay == nil && NodeDelay.cancelled.legacyDelay == nil)
        #expect(!NodeDelay.coreNotReady.isResult && NodeDelay.timedOut.isResult)
    }
}

/// Which connections a change moves, and which it never cuts.
struct ReconnectPolicyTests {
    typealias Connection = MihomoController.Connection

    static func connection(_ id: String, host: String = "", ip: String = "", process: String = "", path: String = "",
                           chains: [String], download: Int64 = 0) -> Connection {
        Connection(id: id, metadata: .init(network: "tcp", host: host, destinationIP: ip, process: process, processPath: path),
                   chains: chains, rule: "Match", rulePayload: "", download: download)
    }

    static let open = [
        connection("google", host: "www.google.com", chains: ["JP-01", "Proxy"]),
        connection("bili", host: "api.bilibili.com", chains: ["DIRECT"]),
        connection("ssh", host: "git.example.com", process: "ssh", chains: ["JP-01", "Proxy"]),
        connection("claude", host: "api.anthropic.com", path: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", chains: ["US-01", "AI"]),
        connection("download", host: "dl.google.com", chains: ["JP-01", "Proxy"], download: 200 << 20),
        connection("ip", ip: "203.0.113.9", chains: ["JP-01", "Proxy"]),
    ]

    @Test func aNodeSwitchMovesOnlyTheGroupsConnectionsAndKeepsShellsAgentsAndDownloads() {
        let plan = ReconnectPolicy.plan(.selection(group: "Proxy"), connections: Self.open)
        #expect(plan.close.sorted() == ["google", "ip"])
        #expect(plan.kept == 2)
    }

    @Test func aRouteMovesMatchingHostsAndAddressesNotEverything() {
        let domain = ReconnectPolicy.plan(.rules(["DOMAIN-SUFFIX,google.com"], target: "US"), connections: Self.open)
        #expect(domain.close == ["google"], "dl.google.com is a large transfer and is kept")
        #expect(domain.kept == 1)
        let cidr = ReconnectPolicy.plan(.rules(["IP-CIDR,203.0.113.0/24"], target: "DIRECT"), connections: Self.open)
        #expect(cidr.close == ["ip"])
        // Already where the rule sends it.
        #expect(ReconnectPolicy.plan(.rules(["DOMAIN-SUFFIX,bilibili.com"], target: "DIRECT"), connections: Self.open).close.isEmpty)
    }

    @Test func aProfileSwitchMovesConnectionsThroughPoliciesThatAreGone() {
        let plan = ReconnectPolicy.plan(.profile(policies: ["DIRECT", "Proxy", "JP-01", "AI"]), connections: Self.open)
        #expect(plan.close.isEmpty, "every policy still exists; the agent's is kept anyway")
        let gone = ReconnectPolicy.plan(.profile(policies: ["DIRECT", "B-Select"]), connections: Self.open)
        #expect(gone.close.sorted() == ["google", "ip"])
        #expect(gone.kept == 3)
    }

    @Test func anUnknownChangeClosesNothing() {
        #expect(ReconnectPolicy.plan(.unknown, connections: Self.open).close.isEmpty)
    }

    @Test func addressMatchingCoversIPv4AndIPv6Prefixes() {
        #expect(HostMatch.contains("IP-CIDR,10.0.0.0/8,no-resolve", address: "10.2.3.4"))
        #expect(!HostMatch.contains("IP-CIDR,10.0.0.0/8", address: "11.0.0.1"))
        #expect(HostMatch.contains("IP-CIDR6,2001:db8::/32", address: "2001:db8:1::5"))
        #expect(!HostMatch.contains("IP-CIDR6,2001:db8::/32", address: "10.0.0.1"))
        #expect(HostMatch.matches("DOMAIN-KEYWORD,goog", host: "www.google.com"))
        #expect(!HostMatch.matches("DOMAIN,google.com", host: "www.google.com"))
    }
}
