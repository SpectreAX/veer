import Foundation
import VeerProxy

/// The bundled DIRECT-only sample profile (Resources/Sample-Direct.yaml): no servers, no
/// secrets, safe to run in the Simulator. It goes through the same path as a file from Files.
extension ProxyStore {
    static var sampleProfileURL: URL? { Bundle.main.url(forResource: "Sample-Direct", withExtension: "yaml") }
    static var sampleProfileName: String { String(localized: "示例配置（仅直连）") }

    /// The sample profile, once imported.
    var sampleProfile: Profile? { profiles.first { $0.name == Self.sampleProfileName } }

    /// Imports the sample (once; again only after it was deleted) and makes it the active profile.
    /// False with `importError` set when it could not be read or saved.
    @discardableResult func importSample(from url: URL? = ProxyStore.sampleProfileURL) -> Bool {
        if let existing = sampleProfile {
            activate(existing.id)
            return true
        }
        guard let url else {
            importError = String(localized: "找不到示例配置。")
            return false
        }
        let before = Set(profiles.map(\.id))
        guard importFile(url), var profile = profiles.first(where: { !before.contains($0.id) }) else { return false }
        profile.name = Self.sampleProfileName
        do {
            try profileStore.saveInfo(profile)
        } catch {
            importError = message(for: error)
        }
        profiles = profileStore.loadAll()
        activate(profile.id)
        return true
    }
}
