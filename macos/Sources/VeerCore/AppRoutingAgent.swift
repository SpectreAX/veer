import Foundation

/// The Agent's app-routing tools. The model never sees a path: it reads apps by a reference
/// (`app-1`) that Veer gives out in a lookup, with their name, bundle ID and what Veer can tell
/// about where their traffic comes from, and proposes changes by those references.
///
/// - `{"apps":{"query":"chrome"}}`: list, inspect and list rules (read-only, no confirmation);
/// - `{"appRoutes":{"changes":[…]}}`: a proposal, shown as a card, checked by the bundled core and
///   applied only as the execution mode allows. Applying it saves the profile's app rules; undo
///   puts the previous ones back.
public struct AppRouteRequest: Sendable, Equatable {
    public struct Domain: Sendable, Equatable {
        public let matchType: String
        public let value: String
        public let target: String
    }

    public let app: String
    public let target: String?
    public let domains: [Domain]
    public let remove: Bool

    static let maxChanges = 8

    static func decode(_ raw: Any) throws -> AppRouteRequest {
        guard let item = raw as? [String: Any], Set(item.keys).isSubset(of: ["app", "target", "domains", "remove"]),
              let app = item["app"] as? String, !app.isEmpty else {
            throw EditorError(String(localized: "appRoutes.changes 的每一项需要 app（apps 返回的编号），可选 target、domains、remove。"))
        }
        let remove = item["remove"] as? Bool ?? false
        let target = item["target"] as? String
        guard remove || target != nil || item["domains"] != nil else {
            throw EditorError(String(localized: "appRoutes 的“\(app.prefix(20))”没有 target，也不是 remove。"))
        }
        let domains = try (item["domains"] as? [Any] ?? []).prefix(16).map { raw -> Domain in
            guard let entry = raw as? [String: Any], Set(entry.keys) == ["matchType", "value", "target"],
                  let type = entry["matchType"] as? String, let value = entry["value"] as? String, let target = entry["target"] as? String,
                  AppRule.DomainRoute.matchTypes.contains(type.uppercased()) else {
                throw EditorError(String(localized: "domains 的每一项需要 matchType（DOMAIN-SUFFIX、DOMAIN 或 DOMAIN-KEYWORD）、value 和 target。"))
            }
            return Domain(matchType: type.uppercased(), value: value, target: target)
        }
        return AppRouteRequest(app: app, target: target, domains: domains, remove: remove)
    }
}

/// What a lookup found: apps on this Mac matching the query, and the profile's app rules.
public struct AppLookupResult: Sendable {
    public let apps: [AppIdentity]
    /// Roots of the apps running now.
    public let running: Set<String>
    public let rules: [AppRule]
    /// Whether app rules route anything now, in words ("规则模式，正在生效").
    public let state: String

    public init(apps: [AppIdentity], running: Set<String>, rules: [AppRule], state: String) {
        self.apps = apps
        self.running = running
        self.rules = rules
        self.state = state
    }
}

/// References handed out to the model in one turn, so a later round can name an app.
public struct AppReferences: Sendable {
    public private(set) var apps: [String: AppIdentity] = [:]
    private var byRoot: [String: String] = [:]

    public init() {}

    mutating func reference(for app: AppIdentity) -> String {
        if let known = byRoot[app.root] { return known }
        let reference = "app-\(apps.count + 1)"
        apps[reference] = app
        byRoot[app.root] = reference
        return reference
    }

    /// The lookup's answer for the model, with real exit names (the engine anonymizes it).
    mutating func message(for result: AppLookupResult, query: String?, lastRound: Bool) -> String {
        var lines = ["Veer 查询了本机应用\(query.map { "（\($0)）" } ?? "")。应用分流现状：\(result.state)"]
        let ruled = Dictionary(result.rules.map { ($0.app.root, $0) }, uniquingKeysWith: { first, _ in first })
        if !result.rules.isEmpty {
            lines.append("已有应用规则（按优先级）：")
            for (index, rule) in result.rules.enumerated() {
                let reference = reference(for: rule.app)
                let domains = rule.domains.map { "\($0.matchType),\($0.value)→\($0.target.promptName)" }.joined(separator: "；")
                let extra = (domains.isEmpty ? "" : "；域名例外 \(domains)") + (rule.enabled ? "" : "（已停用）")
                lines.append("\(index + 1). \(reference) \(rule.app.name)：\(rule.target.promptName)\(extra)")
            }
        }
        let matches = result.apps.filter { ruled[$0.root] == nil }.prefix(20)
        lines.append(matches.isEmpty ? "没有其他匹配的应用。" : "匹配的应用：")
        for app in matches {
            var facts = [app.kind == .bundle ? "应用" : "命令行工具"]
            if let id = app.bundleID { facts.append(id) }
            if result.running.contains(app.root) { facts.append("正在运行") }
            facts.append(app.flavor.promptNote)
            lines.append("- \(reference(for: app)) \(app.name)（\(facts.joined(separator: "，"))）")
        }
        lines.append(lastRound ? "这是最后一次查询，请直接给出 appRoutes 或澄清问题。" : "提出修改时只用上面的编号。")
        return lines.joined(separator: "\n")
    }
}

/// One app's change, with real names, as the card shows it and Veer applies it.
public struct AppRouteChange: Codable, Sendable, Equatable, Identifiable {
    public let app: AppIdentity
    /// Nil keeps the current exit (only domain routes change).
    public let target: AppRule.Target?
    public let domains: [AppRule.DomainRoute]
    public let remove: Bool
    public var id: String { app.root }

    public init(app: AppIdentity, target: AppRule.Target?, domains: [AppRule.DomainRoute] = [], remove: Bool = false) {
        self.app = app
        self.target = target
        self.domains = domains
        self.remove = remove
    }
}

/// An Agent turn's app-routing proposal and what became of it.
public struct AppRoutingProposal: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, applied, undone, discarded, failed }

    public var changes: [AppRouteChange]
    public var status: Status
    /// The profile the rules were proposed for; a different active profile makes the card stale.
    public var profileID: UUID?
    /// The profile's rules before applying, for undo.
    public var previous: [AppRule]?
    /// The bundled core's check of the config the change makes.
    public var validation: ValidationResult?
    /// Why applying failed, or what applying did.
    public var message: String?

    public init(changes: [AppRouteChange], status: Status = .pending, profileID: UUID? = nil) {
        self.changes = changes
        self.status = status
        self.profileID = profileID
    }

    /// `rules` with the changes made: a new app goes last, a known one keeps its place.
    public func applying(to rules: [AppRule]) -> [AppRule] {
        var result = rules
        for change in changes {
            let index = result.firstIndex { $0.app.root == change.app.root }
            if change.remove {
                if let index { result.remove(at: index) }
                continue
            }
            if let index {
                if let target = change.target { result[index].target = target }
                if !change.domains.isEmpty { result[index].domains = change.domains }
                result[index].enabled = true
            } else {
                result.append(AppRule(app: change.app, target: change.target ?? .followProfile, domains: change.domains, source: .agent))
            }
        }
        return result
    }
}

extension AppRouteRequest {
    /// With real apps and exits: `references` from this turn's lookups, `restore` from labels to names.
    func resolved(references: AppReferences, draft: ConfigDocument, restore: (String) -> String) throws -> AppRouteChange {
        guard let app = references.apps[app.trimmingCharacters(in: .whitespaces)] else {
            throw EditorError(String(localized: "appRoutes 里的“\(app.prefix(20))”不是 apps 返回的编号。请先用 apps 查询，只用返回的编号。"))
        }
        func target(_ raw: String, allowsProfile: Bool) throws -> AppRule.Target {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch value.uppercased() {
            case "PROFILE" where allowsProfile: return .followProfile
            case "DIRECT": return .direct
            case "REJECT": return .reject
            default:
                guard let found = draft.target(id: value) ?? draft.target(named: restore(value)) ?? draft.target(named: value), found.kind != .builtin else {
                    throw EditorError(String(localized: "appRoutes 里的出口“\(value.prefix(30))”不存在。只能用配置里的出口标签、DIRECT、REJECT 或 PROFILE。"))
                }
                return .policy(found.name)
            }
        }
        let domains = try self.domains.map { domain -> AppRule.DomainRoute in
            let route = AppRule.DomainRoute(matchType: domain.matchType, value: domain.value, target: try target(domain.target, allowsProfile: false))
            guard route.isValid else { throw EditorError(String(localized: "域名例外“\(domain.value.prefix(40))”无效。")) }
            return route
        }
        return AppRouteChange(app: app, target: try self.target.map { try target($0, allowsProfile: true) }, domains: domains, remove: remove)
    }
}

extension AppRule.Target {
    /// How the model reads an exit: real names here, anonymized with the rest of the message.
    public var promptName: String {
        switch self {
        case .followProfile: "PROFILE"
        case .direct: "DIRECT"
        case .reject: "REJECT"
        case .policy(let name): name
        }
    }
}

extension AppIdentity.Flavor {
    var promptNote: String {
        switch self {
        case .native: "流量来自它自己的进程"
        case .electron: "Electron 应用，含辅助进程"
        case .chromium: "Chromium 内核，网络请求来自包内的辅助进程"
        case .webKit: "WebKit：网页请求来自所有 WebKit 应用共用的系统进程，无法单独控制"
        case .system: "系统应用：部分流量来自共享的系统进程"
        case .commandLine: "按可执行文件路径匹配"
        }
    }
}
