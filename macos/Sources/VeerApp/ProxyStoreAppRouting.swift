import AppKit
import VeerCore
import VeerProxy

/// Why app rules would not route anything right now, apart from the rules themselves.
enum AppRoutingGate: Equatable {
    case inEffect
    /// Rules are saved and load with the next start.
    case coreStopped
    /// Global and Direct send everything one way, without looking at any rule.
    case notRuleMode(ProxyStore.Mode)
    /// `find-process-mode: off`: the core never learns which process a connection is from.
    case processMatchingOff
}

/// App routing's part of `ProxyStore`: apps found on this Mac, the running ones, and what views follow.
struct AppRoutingState {
    /// From the cache first, then a scan.
    var catalog: [AppIdentity] = []
    /// Read when the app list opens.
    var running: [AppIdentity] = []
    var scanning = false
    /// Changes when a profile's app rules change, for the views that show them.
    var revision = 0
    /// An app to select on the App Routing view when it next shows, from another page (`AppIdentity.id`).
    var focus: String?
    /// How long the last scan and the last change took, for the performance notes.
    var scanDuration: TimeInterval?
    var lastApply: TimeInterval?
}

/// App routing (`AppRule`): the apps on this Mac, and each profile's app rules in its layer.
extension ProxyStore {
    // MARK: Apps

    var appCatalogStore: AppCatalogStore { AppCatalogStore(paths: paths) }
    var appCatalog: [AppIdentity] {
        get { apps.catalog }
        set { apps.catalog = newValue }
    }

    var runningApps: [AppIdentity] {
        get { apps.running }
        set { apps.running = newValue }
    }

    var scanningApps: Bool {
        get { apps.scanning }
        set { apps.scanning = newValue }
    }

    var appRulesRevision: Int {
        get { apps.revision }
        set { apps.revision = newValue }
    }

    var appRoutingFocus: String? {
        get { apps.focus }
        set { apps.focus = newValue }
    }

    /// The apps found last time at once, then a scan that reads only new or changed bundles.
    /// Running apps come from the system's list, never by inspecting processes.
    func loadApps(rescan: Bool = false) {
        let store = appCatalogStore
        if appCatalog.isEmpty { appCatalog = store.cached() }
        refreshRunningApps()
        guard rescan || appCatalog.isEmpty, !scanningApps else { return }
        scanningApps = true
        Task {
            let started = Date()
            let found = await Task.detached(priority: .userInitiated) { store.scan() }.value
            appCatalog = found
            scanningApps = false
            apps.scanDuration = Date().timeIntervalSince(started)
            refreshAppPaths()
        }
    }

    func refreshRunningApps() {
        let bundles = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap(\.bundleURL)
        let store = appCatalogStore
        Task {
            let apps = await Task.detached(priority: .utility) { bundles.compactMap(store.identity(ofBundle:)) }.value
            var seen = Set<String>()
            runningApps = apps.filter { seen.insert($0.root).inserted }
        }
    }

    /// An app moved or updated (same bundle ID, new path or helpers): its rules follow it.
    private func refreshAppPaths() {
        guard let id = activeProfileID else { return }
        let rules = appRules(of: id)
        let byID = Dictionary(appCatalog.compactMap { app in app.bundleID.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        var changed = rules
        for index in changed.indices {
            let app = changed[index].app
            guard let bundleID = app.bundleID, let found = byID[bundleID], !FileManager.default.fileExists(atPath: app.root),
                  found.root != app.root else { continue }
            changed[index].app = found
        }
        guard changed != rules else { return }
        Task { try? await setAppRules(changed, for: id) }
    }

    /// Every app Veer knows, for telling which one a connection came from.
    var appAttribution: AppAttribution {
        let ruled = activeProfileID.map { appRules(of: $0).map(\.app) } ?? []
        return AppAttribution(apps: ruled + runningApps + appCatalog)
    }

    // MARK: Rules

    func appRules(of id: UUID) -> [AppRule] { routingStore.load(id).appRules }

    /// Where app rules stand on the running core.
    var appRoutingGate: AppRoutingGate {
        if !settings.processMatching { return .processMatchingOff }
        if !isRunning { return .coreStopped }
        if mode != .rule { return .notRuleMode(mode) }
        return .inEffect
    }

    /// Saves a profile's app rules, after the bundled core has checked the config they make. On the
    /// running core they take effect by reloading the config, which keeps open connections on
    /// their old route (`reconnect(_:)` moves an app's). A reload the core refuses puts the
    /// previous rules back.
    /// The config `rules` would make for a profile, and the bundled core's check of it; nothing is saved.
    func checkAppRules(_ rules: [AppRule], for id: UUID) async throws -> (EffectiveConfig, ValidationResult) {
        var layer = routingStore.load(id)
        layer.appRules = rules
        let profile = try profileStore.text(of: id)
        var running = settings
        running.mixedPort = proxyPort
        let settingsCopy = running, validator = MihomoValidator(binary: binary, geodata: paths.core)
        return try await Task.detached(priority: .userInitiated) { () -> (EffectiveConfig, ValidationResult) in
            let effective = try layer.apply(to: profile)
            let yaml = try RuntimeConfig.build(profile: effective.text, settings: settingsCopy, controllerPort: 0, secret: "")
            return (effective, await validator.validate(yaml))
        }.value
    }

    @discardableResult func setAppRules(_ rules: [AppRule], for id: UUID) async throws -> [AppRule]? {
        try await coreConfigWork.run { [self] in try await commitAppRules(rules, for: id) }
    }

    private func commitAppRules(_ rules: [AppRule], for id: UUID) async throws -> [AppRule]? {
        let started = Date()
        while true {
            let previous = routingStore.load(id)
            guard rules != previous.appRules else { return nil }
            let (effective, check) = try await checkAppRules(rules, for: id)
            guard profiles.contains(where: { $0.id == id }) else { return nil }
            // A node or routing edit may have been saved while the validator was running.
            guard routingStore.load(id) == previous else { continue }
            if check.status == .failed { throw EditorError([check.message, check.detail].compactMap { $0 }.joined(separator: "\n")) }
            var layer = previous
            layer.appRules = rules
            try saveAppRuleLayer(layer, for: id)
            remember(effective, for: id)
            if switchingTo == nil, id == activeProfileID, isRunning {
                do {
                    _ = try await reloadRunningCoreNow(profile: id)
                } catch {
                    try await restoreAppRules(previous.appRules, for: id, after: error)
                }
            }
            apps.lastApply = Date().timeIntervalSince(started)
            return previous.appRules
        }
    }

    private func saveAppRuleLayer(_ layer: RoutingLayer, for id: UUID) throws {
        try routingStore.save(layer, for: id)
        forgetEffective(id)
        appRulesRevision += 1
    }

    private func restoreAppRules(_ rules: [AppRule], for id: UUID, after error: Error) async throws -> Never {
        guard profiles.contains(where: { $0.id == id }) else { throw error }
        do {
            var restored = routingStore.load(id)
            restored.appRules = rules
            try saveAppRuleLayer(restored, for: id)
            if switchingTo == nil { _ = try await reloadRunningCoreNow(profile: id) }
        } catch let rollbackError {
            throw EditorError(String(localized: "无法恢复之前的应用规则：\(message(for: rollbackError))"))
        }
        throw EditorError(String(localized: "内核没有接受新的应用规则，已恢复之前的规则：\(message(for: error))"))
    }

    /// The same, with an undo on `manager` that puts the previous rules back (and a redo).
    func setAppRules(_ rules: [AppRule], for id: UUID, undo manager: UndoManager?, actionName: String) async throws {
        guard let previous = try await setAppRules(rules, for: id) else { return }
        registerAppRulesUndo(restoring: previous, then: rules, profile: id, actionName: actionName, manager: manager)
    }

    /// Registered while the manager undoes, the inner registration becomes the redo; the change
    /// itself runs after, since it waits for the core's check.
    func registerAppRulesUndo(restoring previous: [AppRule], then current: [AppRule], profile id: UUID, actionName: String, manager: UndoManager?) {
        manager?.registerUndo(withTarget: self) { store in
            store.registerAppRulesUndo(restoring: current, then: previous, profile: id, actionName: actionName, manager: manager)
            Task { @MainActor in
                do { try await store.setAppRules(previous, for: id) } catch { store.notice = store.message(for: error) }
            }
        }
        manager?.setActionName(actionName)
    }

    /// One app's rule set to `target`, from the connections menu: an existing rule keeps its place
    /// and domain routes, a new one goes last.
    func routeApp(_ app: AppIdentity, to target: AppRule.Target, undo manager: UndoManager?) async throws {
        guard let id = activeProfileID else { return }
        var rules = appRules(of: id)
        if let index = rules.firstIndex(where: { $0.app.root == app.root }) {
            rules[index].target = target
            rules[index].enabled = true
        } else {
            rules.append(AppRule(app: app, target: target, source: .connections))
        }
        try await setAppRules(rules, for: id, undo: manager, actionName: String(localized: "修改应用规则"))
    }

    /// Adds or replaces the rule for an app (one rule per app), keeping its place in the order.
    func setAppRule(_ rule: AppRule, for id: UUID) async throws {
        var rules = appRules(of: id)
        if let index = rules.firstIndex(where: { $0.id == rule.id || $0.app.id == rule.app.id && $0.app.root == rule.app.root }) {
            rules[index] = AppRule(id: rules[index].id, app: rule.app, target: rule.target, domains: rule.domains, enabled: rule.enabled,
                                   source: rule.source, createdAt: rules[index].createdAt)
        } else {
            rules.append(rule)
        }
        try await setAppRules(rules, for: id)
    }

    /// Closes the open connections from an app's processes, so they reconnect by the new rules.
    @discardableResult func reconnect(_ app: AppIdentity) async -> Int {
        guard let controller, let list = try? await controller.connections() else { return 0 }
        let ids = list.filter { app.owns(processPath: $0.metadata.processPath ?? "") }.map(\.id)
        for id in ids { try? await controller.closeConnection(id) }
        return ids.count
    }

    /// The Agent's app lookup: apps matching `query` (all running ones and the profile's rules
    /// without one), with the profile's rules and whether they route now.
    func appLookup(_ query: String?, profile id: UUID) async -> AppLookupResult {
        loadApps()
        if appCatalog.isEmpty {
            let store = appCatalogStore
            appCatalog = await Task.detached(priority: .userInitiated) { store.scan() }.value
        }
        let rules = appRules(of: id)
        let pool = runningApps + appCatalog.filter { app in !runningApps.contains { $0.root == app.root } }
        let text = query?.lowercased()
        let apps = text.map { text in
            pool.filter { $0.name.lowercased().contains(text) || ($0.bundleID?.lowercased().contains(text) ?? false)
                || URL(fileURLWithPath: $0.root).lastPathComponent.lowercased().contains(text) }
        } ?? runningApps
        let state: String = switch appRoutingGate {
        case .inEffect: "规则模式，应用规则正在生效。"  // for the AI
        case .coreStopped: "内核没有运行，规则保存后在下次启动时生效。"  // for the AI
        case .notRuleMode(let mode): "现在是\(mode.title)模式，应用规则不起作用。"  // for the AI
        case .processMatchingOff: "设置里关闭了“按进程匹配”，应用规则不起作用。"  // for the AI
        }
        return AppLookupResult(apps: apps, running: Set(runningApps.map(\.root)), rules: rules, state: state)
    }

    /// The exits an app rule can name: the active profile's groups, then its nodes.
    func appRouteTargets() async -> (groups: [String], nodes: [String]) {
        guard let id = activeProfileID, let text = try? await effectiveTextInBackground(of: id) else { return ([], []) }
        return await Task.detached {
            let targets = (try? ConfigDocument.parse(text))?.targets ?? []
            return (targets.filter { $0.kind == .group }.map(\.name), targets.filter { $0.kind == .node }.map(\.name))
        }.value
    }

    /// Opens the App Routing view on an app's rule.
    func showAppRules(for app: AppIdentity) {
        appRoutingFocus = app.id
        UserDefaults.standard.set(true, forKey: "proxiesShowApps")
        page = .proxies
    }

    /// What the generated rules are and what became of each, for the active profile.
    var appRoutingReport: AppRuleBuilder.Report? { effective?.appRouting }

    /// Which app rule a connection hit, from the rule and payload the core reports, said for the
    /// route map: "App routing: Chrome → Japan", or the local-network guard.
    func appRuleHit(_ row: ConnectionRow, attribution: AppAttribution) -> String? {
        guard let line = appRoutingReport?.line(reportedType: row.ruleType, payload: row.rulePayload) else { return nil }
        guard line.role != .localGuard else { return String(localized: "应用分流：局域网保持直连") }
        let name = attribution.app(forProcessPath: row.processPath)?.name
            ?? activeProfileID.flatMap { id in appRules(of: id).first { $0.id == line.ruleID }?.app.name } ?? "?"
        let target = AppRule.Target(policy: line.target).title
        return line.role == .domain ? String(localized: "应用分流：\(name) 的域名例外 → \(target)") : String(localized: "应用分流：\(name) → \(target)")
    }

    /// The open connections from an app right now.
    func connectionCount(of app: AppIdentity) -> Int {
        connections.count { app.owns(processPath: $0.processPath ?? "") }
    }
}
