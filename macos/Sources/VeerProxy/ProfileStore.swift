import Foundation
import VeerCore

/// A config Veer can run: a local file or a subscription.
public struct Profile: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var isSubscription: Bool
    public var updatedAt: Date
    public var nodeCount: Int
    public var usage: SubscriptionUsage?
    /// From the subscription's `profile-update-interval` header, in hours.
    public var updateIntervalHours: Int?
    /// Why the last automatic update failed; nil after a success.
    public var updateError: String?

    /// When the subscription is due for an automatic update: its own interval, else daily.
    public var nextUpdate: Date { updatedAt.addingTimeInterval(TimeInterval(max(updateIntervalHours ?? 24, 1)) * 3600) }

    public init(id: UUID = UUID(), name: String, isSubscription: Bool, updatedAt: Date = .now, nodeCount: Int, usage: SubscriptionUsage? = nil) {
        self.id = id
        self.name = name
        self.isSubscription = isSubscription
        self.updatedAt = updatedAt
        self.nodeCount = nodeCount
        self.usage = usage
    }
}

/// Profiles on disk: `profiles.json` lists them, `profiles/<id>.yaml` holds each config, and
/// subscription links live in the secret store, never in the index.
public final class ProfileStore: @unchecked Sendable {
    public let paths: VeerPaths
    public let secrets: KeyStoring
    private let lock = NSLock()

    public init(paths: VeerPaths, secrets: KeyStoring? = nil) {
        self.paths = paths
        self.secrets = secrets ?? paths.makeSecretStore()
    }

    public func loadAll() -> [Profile] {
        lock.withLock {
            guard let data = try? Data(contentsOf: paths.profileIndex) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([Profile].self, from: data)) ?? []
        }
    }

    public func text(of id: UUID) throws -> String {
        do { return try String(contentsOf: file(id), encoding: .utf8) } catch {
            throw EditorError(String(localized: "找不到这个配置的文件，可能已被删除。"))
        }
    }

    /// Adds or replaces `profile` and its config text.
    public func save(_ profile: Profile, text: String) throws {
        try paths.prepare()
        try lock.withLock {
            try Data(text.utf8).write(to: file(profile.id), options: .atomic)
            var all = Self.read(paths.profileIndex)
            if let index = all.firstIndex(where: { $0.id == profile.id }) { all[index] = profile } else { all.append(profile) }
            try Self.write(all, to: paths.profileIndex)
        }
    }

    /// Replaces a profile's entry in the index, leaving its config text alone.
    public func saveInfo(_ profile: Profile) throws {
        try lock.withLock {
            var all = Self.read(paths.profileIndex)
            guard let index = all.firstIndex(where: { $0.id == profile.id }) else { return }
            all[index] = profile
            try Self.write(all, to: paths.profileIndex)
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(id))
            try? Self.write(Self.read(paths.profileIndex).filter { $0.id != id }, to: paths.profileIndex)
        }
        secrets.delete(for: Self.secretKey(id))
    }

    public func subscriptionURL(of id: UUID) -> URL? { secrets.read(for: Self.secretKey(id)).flatMap(URL.init(string:)) }

    public func setSubscriptionURL(_ url: URL, for id: UUID) throws { try secrets.save(url.absoluteString, for: Self.secretKey(id)) }

    public func forgetSubscriptionURL(of id: UUID) { secrets.delete(for: Self.secretKey(id)) }

    private func file(_ id: UUID) -> URL { paths.profiles.appendingPathComponent("\(id.uuidString).yaml") }

    static func secretKey(_ id: UUID) -> String { "subscription-\(id.uuidString)" }

    private static func read(_ url: URL) -> [Profile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    private static func write(_ profiles: [Profile], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }
}

/// A subscription running low on traffic or close to its end, worth one notification.
public enum UsageAlert: String, Sendable, CaseIterable {
    case traffic, expiry

    /// The alerts `usage` calls for at `now`: under 10% of the traffic left, or three days or
    /// less until it expires (or already expired).
    public static func due(_ usage: SubscriptionUsage?, now: Date = .now) -> Set<UsageAlert> {
        guard let usage else { return [] }
        var alerts: Set<UsageAlert> = []
        if let total = usage.total, total > 0, let used = usage.used, total - used < total / 10 { alerts.insert(.traffic) }
        if let expire = usage.expire, expire.timeIntervalSince(now) < 3 * 86_400 { alerts.insert(.expiry) }
        return alerts
    }
}

/// Which usage alerts went out, so each is sent once while its condition holds. When it clears
/// (a renewed plan, a new month), the next time it holds it is sent again.
public struct UsageAlertLedger {
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The alerts to send now for `profile`, recorded as sent.
    public func take(for profile: Profile, now: Date = .now) -> [UsageAlert] {
        let due = UsageAlert.due(profile.usage, now: now)
        var send: [UsageAlert] = []
        for alert in UsageAlert.allCases {
            let key = "usageAlert.\(profile.id.uuidString).\(alert.rawValue)"
            if !due.contains(alert) {
                defaults.removeObject(forKey: key)
            } else if !defaults.bool(forKey: key) {
                defaults.set(true, forKey: key)
                send.append(alert)
            }
        }
        return send
    }
}
