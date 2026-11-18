import Foundation
import os
import VeerCore
import VeerProxy

/// Timing one start of the core, and deciding when it is ready.
extension ProxyStore {
    enum Readiness { case ready, timedOut, calledOff }

    private static let signposter = OSSignposter(subsystem: "com.yamax.veer", category: "Startup")
    private static let startupLog = Logger(subsystem: "com.yamax.veer", category: "Startup")

    /// A new timeline, from the click; the interval shows in Instruments.
    func beginStartup() -> OSSignpostIntervalState {
        startup = StartupTimeline()
        return Self.signposter.beginInterval("Start")
    }

    func endStartup(_ state: OSSignpostIntervalState) { Self.signposter.endInterval("Start", state) }

    /// Notes a step of the start under way, in the timeline and as a signpost.
    func reached(_ milestone: StartupTimeline.Milestone) {
        startup?.mark(milestone)
        Self.signposter.emitEvent("Milestone", "\(milestone.rawValue, privacy: .public)")
    }

    /// The steps so far, in the system log: names and times only.
    func logStartup(_ event: String) {
        guard let startup else { return }
        Self.startupLog.info("\(event, privacy: .public):\n\(startup.report, privacy: .public)")
    }

    /// Waits up to a minute for the new core: the first start can download geodata before the
    /// controller answers. Ready means the controller answers, the proxy port accepts connections
    /// and the core carries what comes in: a process that has only started carries no traffic
    /// yet, and the page must not say it does.
    func coreBecomesReady(_ controller: MihomoController, controllerPort: Int, proxyPort: Int) async throws -> Readiness {
        let began = ContinuousClock.now
        var answers = false
        while ContinuousClock.now - began < ReadinessPolling.limit {
            if phase != .starting { return .calledOff }
            // The port first: asking a controller that isn't listening costs a failed request.
            if !answers, Ports.inUse(controllerPort), (try? await controller.version()) != nil {
                answers = true
                reached(.controllerReady)
            }
            if answers, Ports.inUse(proxyPort) {
                reached(.listening)
                guard await carriesTraffic(controller, controllerPort: controllerPort, proxyPort: proxyPort) else { return .calledOff }
                reached(.proxyReady)
                return .ready
            }
            try await Task.sleep(for: ReadinessPolling.interval(after: ContinuousClock.now - began))
        }
        return phase == .starting ? .timedOut : .calledOff
    }

    /// Waits while the core reads its rule sets and node lists, which is when it drops traffic.
    /// The controller knows when all of them have loaded; when one has failed it never says so,
    /// and then a tunnel the core keeps open is the proof. False when the start was called off.
    private func carriesTraffic(_ controller: MihomoController, controllerPort: Int, proxyPort: Int) async -> Bool {
        let began = ContinuousClock.now
        while phase == .starting, ContinuousClock.now - began < ReadinessPolling.loadingLimit {
            if (try? await controller.providersLoaded()) == true { return true }
            let answer = await Task.detached { TunnelProbe.ask(proxyPort: proxyPort, controllerPort: controllerPort) }.value
            if answer == .carried { return true }
            try? await Task.sleep(for: ReadinessPolling.interval(after: ContinuousClock.now - began))
        }
        if phase == .starting { logStartup("Stopped waiting for rule sets and node lists") }
        return phase == .starting
    }
}
