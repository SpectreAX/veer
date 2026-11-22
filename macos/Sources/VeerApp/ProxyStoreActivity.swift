import Foundation
import VeerCore
import VeerProxy

/// One short-lived piece of feedback for subscription work, whatever started it (the profile menu,
/// Manage Profiles, the Proxy menu, the Agent, an import): updating, updated, or failed with why.
/// It is shown once, at the foot of the window (`ActivityToast`), not next to each entry point.
struct Activity: Equatable, Identifiable {
    enum Kind: Equatable {
        case updating
        /// The subscription's content was saved; `reloaded` when the running core took it.
        case updated(reloaded: Bool)
        /// The same link was imported again: the existing profile was updated, not duplicated.
        case reimported(reloaded: Bool)
        /// The last good config stays in use.
        case failed(String)
    }

    let id = UUID()
    let profileID: UUID
    let name: String
    var kind: Kind

    var message: String {
        switch kind {
        case .updating: String(localized: "正在更新“\(name)”…")
        case .updated(true), .reimported(true): String(localized: "“\(name)”已更新并应用")
        case .updated(false), .reimported(false): String(localized: "“\(name)”已更新")
        case .failed(let reason): String(localized: "“\(name)”更新失败：\(reason)")
        }
    }

    var isFailure: Bool { if case .failed = kind { true } else { false } }
    var isRunning: Bool { kind == .updating }
}

extension ProxyStore {
    /// Seconds a success stays: long enough to read, gone before it is in the way.
    static let activityLinger: Duration = .seconds(3)

    func showActivity(_ activity: Activity) {
        activityDismissal?.cancel()
        self.activity = activity
        // A failure stays until it is dismissed or retried: it has a reason to read and an action.
        guard !activity.isFailure, !activity.isRunning else { return }
        let id = activity.id
        activityDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.activityLinger)
            guard let self, !Task.isCancelled, self.activity?.id == id else { return }
            self.activity = nil
        }
    }

    func dismissActivity() {
        activityDismissal?.cancel()
        activity = nil
    }

    /// Runs the failed update again.
    func retryActivity() {
        guard let activity, activity.isFailure else { return }
        update(activity.profileID)
    }
}

/// Which copy of a duplicated subscription a merge keeps, which it removes, and which it leaves
/// because they hold routing changes of their own.
struct MergePlan {
    let keep: Profile
    let remove: [Profile]
    let keptWithChanges: [Profile]

    var profileIDs: Set<UUID> { Set([keep.id] + remove.map(\.id) + keptWithChanges.map(\.id)) }
}

/// A duplicate removed in Manage Profiles, available to restore while the sheet is open.
struct RemovedProfile {
    let profile: Profile
    let text: String
    let link: URL
}
