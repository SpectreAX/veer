import Foundation
import VeerProxy

extension ProxyStore {
    /// The one to run as the user: an update from Settings if there is one, else what came with Veer.
    var activeBinary: URL? { hasUpdatedCore ? coreUpdater.installed : binary }

    var coreUpdater: CoreUpdater { CoreUpdater(paths: paths) }

    /// The one in use or next to be: TUN runs only the bundled one, whatever else is installed.
    var reportedBinary: URL? { settings.tun ? binary : activeBinary }

    /// Whether what is running isn't the core a restart would run.
    var coreNeedsRestart: Bool { isRunning && !tunActive && runningCoreRevision != coreRevision }

    /// An update that is no longer ahead of what came with Veer, or won't run, gives way to it.
    func dropStaleCoreUpdate() async {
        guard hasUpdatedCore, let binary else { return }
        let bundled = await CoreUpdater.version(of: binary)
        let updated = await CoreUpdater.version(of: coreUpdater.installed)
        if updated == nil || !CoreUpdater.isNewer(updated ?? "", than: bundled) { useBundledCore() }
    }

    func useBundledCore() {
        do {
            try coreUpdater.remove()
            hasUpdatedCore = false
            coreRevision += 1
        } catch {
            notice = message(for: error)
        }
    }

    func installCore(_ release: CoreRelease) async throws {
        let port = isRunning ? proxyPort : nil
        try await coreUpdater.install(release) { try await CoreUpdater.download($0, proxyPort: port) }
        hasUpdatedCore = true
        coreRevision += 1
    }
}
