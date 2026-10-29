import AppKit
import Sparkle

/// Sparkle 2: checks the appcast once a day and asks before installing. It runs only inside a
/// built Veer.app; `swift run` and snapshots have no bundle to replace.
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let bundled = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    func start() {
        guard let controller else { return }
        do { try controller.updater.start() } catch { NSLog("Veer: Sparkle did not start: \(error.localizedDescription)") }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Veer may be in the menu bar only; the update window needs a Dock presence to show.
    func checkForUpdates() {
        guard let controller else { return }
        DockPresence.windowOpened()
        controller.checkForUpdates(nil)
    }
}
