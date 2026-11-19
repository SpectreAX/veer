import Foundation
import VeerProxy

/// Where traffic leaves for the internet, shown on the overview.
extension ProxyStore {
    /// Asks public IP services, through Veer's own port, where traffic leaves, until one answers or
    /// `ExitProbe` runs out of time. Runs again after a node or mode switch.
    func checkExit(after delay: Duration = .zero) {
        exitCheck?.cancel()
        guard showExitIP, isRunning else { exit = nil; exitCheck = nil; return }
        // A failure is not the answer to a new question; what is known stays until it is replaced.
        if exit == .unknown { exit = nil }
        let port = proxyPort
        exitCheck = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await ExitProbe.run { await ExitInfo.lookUp(throughPort: port) }
            guard !Task.isCancelled else { return }
            exit = found ?? ExitInfo.unknown
            exitCheck = nil
            // The first answer through the proxy after a start: traffic is known to get out.
            if found != nil, isRunning, startup?.time(of: .networkReachable) == nil {
                reached(.networkReachable)
                logStartup("First request through the proxy")
            }
        }
    }

    /// The person asked: back to detecting, so the page shows that something is happening.
    func recheckExit() {
        exit = nil
        checkExit()
    }

    /// Opening the dashboard must not start the time over on a check already under way.
    func checkExitIfNeeded() {
        if exit == nil, exitCheck == nil { checkExit() }
    }
}
