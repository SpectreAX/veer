import Foundation

/// When each step of one start of the core was reached, measured from the click. Kept so a slow
/// start can be read afterwards instead of guessed at.
public struct StartupTimeline: Sendable, Equatable {
    /// In the order a start reaches them. A started process is not a ready proxy: the page says
    /// "running" only at `proxyReady`, and traffic is known to get out only at `networkReachable`.
    public enum Milestone: String, Sendable, CaseIterable {
        /// The profile is read, "my routing" is applied and its groups are checked.
        case configReady
        /// The TUN helper has answered; only when TUN is on.
        case helperChecked
        /// The runtime config and its rule set files are written.
        case runtimeWritten
        case processStarted
        /// The core's controller answers.
        case controllerReady
        /// The mixed port accepts connections. The core may still be reading rule sets and node
        /// lists, and until it has, it drops what comes in.
        case listening
        /// The core carries traffic (`TunnelProbe`).
        case proxyReady
        /// The groups and nodes are on the page.
        case uiReady
        /// A request through the proxy came back.
        case networkReachable
    }

    public struct Step: Sendable, Equatable {
        public let milestone: Milestone
        /// Since the click.
        public let at: Duration
        /// Since the step before it.
        public let took: Duration
    }

    public let began: ContinuousClock.Instant
    private var reached: [Milestone: Duration] = [:]

    public init(began: ContinuousClock.Instant = .now) { self.began = began }

    /// The latest time counts: a start that falls back from TUN starts the process twice.
    public mutating func mark(_ milestone: Milestone, at instant: ContinuousClock.Instant = .now) {
        reached[milestone] = instant - began
    }

    public func time(of milestone: Milestone) -> Duration? { reached[milestone] }

    /// The milestones reached, in the order they were reached.
    public var steps: [Step] {
        var previous = Duration.zero
        return reached.sorted { $0.value == $1.value ? Self.order($0.key) < Self.order($1.key) : $0.value < $1.value }.map { milestone, at in
            defer { previous = at }
            return Step(milestone: milestone, at: at, took: at - previous)
        }
    }

    /// One line per step, for the log and the diagnostics bundle: `controllerReady  +212 ms  (21 ms)`.
    public var report: String {
        steps.map { step in
            let name = step.milestone.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)
            return "\(name) +\(Self.milliseconds(step.at)) ms  (\(Self.milliseconds(step.took)) ms)"
        }.joined(separator: "\n")
    }

    public static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }

    private static func order(_ milestone: Milestone) -> Int { Milestone.allCases.firstIndex(of: milestone) ?? 0 }
}

/// How often to ask a core that is starting whether it is ready: it usually is within a quarter
/// of a second, so the first two seconds ask every 20 ms, and after that (the first start may
/// download geodata for a minute) every 100 ms.
public enum ReadinessPolling {
    public static let limit = Duration.seconds(60)
    /// How long to wait for a core that listens to start carrying traffic. A link that does not
    /// answer costs the core 5 seconds each, one after another; past this the page stops waiting
    /// and says running, as it did before there was a check.
    public static let loadingLimit = Duration.seconds(30)

    public static func interval(after waited: Duration) -> Duration {
        waited < .seconds(2) ? .milliseconds(20) : .milliseconds(100)
    }
}
