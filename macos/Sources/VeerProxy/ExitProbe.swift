import Foundation

/// Keeps asking where traffic leaves until there is an answer or time is up. A core that has just
/// started, or a node just switched to, may not answer yet, so one failure says nothing.
public enum ExitProbe {
    /// How long a failure takes to count. A try already under way is allowed to finish.
    public static let timeout = Duration.seconds(20)
    public static let interval = Duration.seconds(2)

    public static func run<Answer: Sendable>(attempt: @Sendable () async -> Answer?) async -> Answer? {
        let clock = ContinuousClock()
        let start = clock.now
        return await run(timeout: timeout, interval: interval, now: { start.duration(to: clock.now) },
                         sleep: { try? await Task.sleep(for: $0) }, attempt: attempt)
    }

    /// `now` is the time since the start. Nil when time ran out or the task was cancelled.
    static func run<Answer: Sendable>(timeout: Duration, interval: Duration, now: () -> Duration,
                                      sleep: (Duration) async -> Void, attempt: @Sendable () async -> Answer?) async -> Answer? {
        while !Task.isCancelled {
            if let answer = await attempt() { return answer }
            guard now() < timeout, !Task.isCancelled else { return nil }
            await sleep(interval)
        }
        return nil
    }
}
