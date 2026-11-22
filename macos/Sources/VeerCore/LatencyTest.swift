import Foundation

/// Where a node's delay stands in Veer's eyes. Only `measured`, `timedOut` and `failed` come from a
/// test of the profile that is running now; the rest say why there is no number.
public enum NodeDelay: Sendable, Equatable, Hashable {
    /// No test of this node in the running profile yet.
    case untested
    /// Asked for and not answered yet (queued or running).
    case testing
    /// The core was not ready (starting, switching profile, stopped) when the test would have run.
    case coreNotReady
    case measured(Int)
    /// The core gave up after the test's timeout.
    case timedOut
    /// Refused, unreachable or not resolvable; the core's message when it gave one.
    case failed(String)
    /// Called off before it ran: a newer test, a profile switch or the core stopping.
    case cancelled

    /// The core's own history, read from `GET /proxies`: 0 is a failed test of any kind.
    public init(history: Int?) {
        switch history {
        case nil: self = .untested
        case 0?: self = .timedOut
        case let delay?: self = .measured(delay)
        }
    }

    init(_ outcome: MihomoController.DelayOutcome) {
        switch outcome {
        case .delay(let delay): self = .measured(delay)
        case .timedOut: self = .timedOut
        case .failed(let reason): self = .failed(reason)
        }
    }

    /// The milliseconds when measured; 0 for a timeout or failure, as the old delay field had it.
    public var legacyDelay: Int? {
        switch self {
        case .measured(let delay): delay
        case .timedOut, .failed: 0
        default: nil
        }
    }

    /// A result that came from a test, as opposed to a state without one.
    public var isResult: Bool {
        switch self {
        case .measured, .timedOut, .failed: true
        default: false
        }
    }
}

/// Tests many nodes through one core without flooding it. Veer used to ask the core to test every
/// node at once (`GET /group/GLOBAL/delay`). Right after `PUT /configs` the core's DNS cache is
/// empty, so every node's server name is looked up at the same moment; against a resolver that limits
/// bursts, most of those lookups were dropped and those nodes recorded a timeout (measured on Mihomo
/// v1.19.29: 261 of 300 nodes at 40 queries a second, 0 of 300 with four at a time). This runs a few
/// at a time, gives the ones that failed one more try once the rest are done, and stops at once
/// when it is cancelled. Results arrive one by one, so a page fills in as they come.
///
/// The width adapts: it starts at `concurrency`, grows by one after each run of successes (up to
/// `maximumConcurrency`) and halves on a failure, so a healthy network is not held to four at a time
/// and a struggling resolver is not pushed harder.
public struct LatencyTest: Sendable {
    public typealias Probe = @Sendable (String) async throws -> MihomoController.DelayOutcome

    /// Four at a time measured best against a limited resolver; more lost nodes to dropped lookups.
    public static let defaultConcurrency = 4
    /// A result this recent is reused by a "fastest node" choice instead of testing again.
    public static let freshFor: TimeInterval = 60

    public var concurrency: Int
    public var maximumConcurrency: Int
    /// Successes in a row before one more test runs at a time.
    static let growAfter = 6
    /// Failures get one more try, alone or two at a time, after everything else ran.
    public var retriesFailures: Bool
    /// For choosing quickly: once every name has started, give each outstanding probe at least
    /// the best measured delay as a response budget, instead of waiting out every timeout.
    /// Those still running are reported `cancelled`.
    public var stopsWhenNoneCanBeatBest = false
    let probe: Probe

    public init(concurrency: Int = Self.defaultConcurrency, maximumConcurrency: Int? = nil, retriesFailures: Bool = true, probe: @escaping Probe) {
        self.concurrency = max(1, concurrency)
        self.maximumConcurrency = max(self.concurrency, maximumConcurrency ?? self.concurrency * 3)
        self.retriesFailures = retriesFailures
        self.probe = probe
    }

    /// Tests `names` once each (duplicates once), reporting each result as it comes. When the task
    /// is cancelled, names not yet started are reported as `cancelled` and nothing more is sent.
    /// A controller that stops answering ends the run: the rest are `coreNotReady`.
    @discardableResult
    public func run(_ names: [String], report: @Sendable (String, NodeDelay) async -> Void) async -> [String: NodeDelay] {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        var run = Progress()
        await pass(unique, width: concurrency, limit: maximumConcurrency, into: &run, report: report)
        if retriesFailures, !run.failed.isEmpty, !Task.isCancelled, !run.controllerGone {
            let failed = run.failed
            run.failed = []
            await pass(failed, width: min(2, concurrency), limit: min(2, concurrency), into: &run, report: report)
        }
        for name in unique where run.results[name] == nil {
            let state: NodeDelay = run.controllerGone ? .coreNotReady : .cancelled
            run.results[name] = state
            await report(name, state)
        }
        return run.results
    }

    private struct Progress {
        var results: [String: NodeDelay] = [:]
        var failed: [String] = []
        var controllerGone = false
    }

    /// How many tests run at once: one more after a run of successes, half after a failure.
    struct Pacing {
        let floor: Int, limit: Int
        var width: Int
        var streak = 0

        init(start: Int, limit: Int) {
            width = start
            floor = min(2, start)
            self.limit = limit
        }

        mutating func adjust(after state: NodeDelay) {
            if case .measured = state {
                streak += 1
                if streak >= LatencyTest.growAfter, width < limit { width += 1; streak = 0 }
            } else {
                streak = 0
                width = max(floor, width / 2)
            }
        }
    }

    private func pass(_ names: [String], width start: Int, limit: Int, into run: inout Progress,
                      report: @Sendable (String, NodeDelay) async -> Void) async {
        var queue = names[...]
        var pacing = Pacing(start: start, limit: limit), running = 0
        var started: [String: ContinuousClock.Instant] = [:], best: Int?
        var wakeAt: ContinuousClock.Instant?
        await withTaskGroup(of: (String?, NodeDelay?).self) { group in
            func next() -> Bool {
                guard running < pacing.width, !Task.isCancelled, !run.controllerGone, let name = queue.popFirst() else { return false }
                running += 1
                started[name] = .now
                let probe = probe
                group.addTask {
                    do { return (name, NodeDelay(try await probe(name))) } catch is CancellationError {
                        return (name, nil)
                    } catch { return (name, Task.isCancelled ? nil : .coreNotReady) }
                }
                return true
            }
            while next() {}
            while let (name, state) = await group.next() {
                // A timer expired. Every timer is for a filled final batch and deadlines can only
                // get earlier as results arrive, so an older timer also means the budget is over.
                guard let name else { break }
                running -= 1
                started[name] = nil
                if let state {
                    if case .measured(let delay) = state { best = min(best ?? delay, delay) }
                    pacing.adjust(after: state)
                    await accept(state, for: name, into: &run, report: report)
                }
                while next() {}
                guard running > 0 else { break }
                if stopsWhenNoneCanBeatBest, queue.isEmpty, let best, let latest = started.values.max() {
                    let deadline = latest.advanced(by: .milliseconds(best))
                    if ContinuousClock.now >= deadline { break }
                    if wakeAt.map({ deadline < $0 }) ?? true {
                        wakeAt = deadline
                        group.addTask {
                            try? await ContinuousClock().sleep(until: deadline, tolerance: .zero)
                            return (nil, nil)
                        }
                    }
                }
            }
            group.cancelAll()
        }
    }

    /// A cancelled run reports nothing more: what it found may belong to a profile that has gone.
    private func accept(_ state: NodeDelay, for name: String, into run: inout Progress, report: @Sendable (String, NodeDelay) async -> Void) async {
        if state == .coreNotReady { run.controllerGone = true }
        guard !Task.isCancelled, state != .coreNotReady else { return }
        run.results[name] = state
        if case .measured = state {} else { run.failed.append(name) }
        await report(name, state)
    }
}
