import Foundation
import Observation
import VeerCore
import VeerMobileKit
import VeerProxy

/// What `AgentStore` (compiled from the Mac sources) asks about navigation: it opens its Mac side
/// panel unless the Agent page shows. On the iPhone the Agent is a tab, so the panel is ignored.
enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, proxies, agent
    var id: String { rawValue }
}

/// The iPhone prototype's proxy store: profiles, "my routing", and the Mihomo core linked into the
/// app, driven over its external controller exactly as the Mac drives its core process.
///
/// Lifted from the Mac `ProxyStore` (macos/Sources/VeerApp/ProxyStore.swift) with the same member
/// names and signatures that `AgentStore` uses. Left out on purpose: TUN and the helper, the system
/// proxy, core updates, diagnostics, backups, usage notifications, onboarding, suggestions, DNS.
/// The core only ever listens on 127.0.0.1 and never takes over the device's network.
@Observable
final class ProxyStore {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        /// Why the core could not start, with the lines that explain it (the core's own error,
        /// then its last log lines).
        case failed(String, log: [String])

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case rule, global, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rule: String(localized: "规则")
            case .global: String(localized: "全局")
            case .direct: String(localized: "直连")
            }
        }
    }

    struct Group: Identifiable, Equatable {
        struct Member: Identifiable, Equatable {
            let name: String
            /// Latest test in ms; 0 when it failed, nil before any test.
            let delay: Int?
            let isGroup: Bool
            var id: String { name }
            /// A group or a built-in policy (DIRECT, REJECT): listed before the nodes.
            var isNode: Bool { !isGroup && !ConfigDocument.builtinPolicies.contains(name) }
        }

        let name: String
        let type: String
        let now: String?
        let members: [Member]
        var id: String { name }
        var isSelectable: Bool { type == "Selector" }
        /// url-test, fallback, load-balance: the core picks the node.
        var isAutomatic: Bool { !isSelectable && ["URLTest", "Fallback", "LoadBalance"].contains(type) }
        /// The member with the lowest working delay.
        var fastest: Member? { members.filter { ($0.delay ?? 0) > 0 }.min { $0.delay! < $1.delay! } }
    }

    /// Nodes of one region in a large group (`ProxyStore.regionSections(of:)`).
    struct RegionSection: Identifiable, Equatable {
        /// ISO code, or nil for the nodes whose region is unknown ("其他").
        let code: String?
        let members: [Group.Member]
        var id: String { code ?? "-" }
        var place: NodeLocator.Place? { code.flatMap(NodeLocator.place) }
        /// Lowest working delay in the section, in ms.
        var fastest: Int? { members.compactMap(\.delay).filter { $0 > 0 }.min() }
    }

    // MARK: State

    /// The tab showing. `AgentStore` reads it; the app sets it from the TabView selection.
    var page: Page = .overview
    /// The Mac's Agent side panel, which `AgentStore.open` turns on. Unused on the iPhone.
    var agentPanel = false

    var phase: Phase = .stopped {
        didSet { if phase != .running { runningSince = nil } }
    }

    var profiles: [Profile] = []
    var activeProfileID: UUID? {
        didSet {
            defaults.set(activeProfileID?.uuidString, forKey: Keys.activeProfile)
            regionMarks = activeProfileID.map { routingStore.load($0).regionMarks } ?? [:]
        }
    }

    /// The active profile's hand-set node regions, by node name.
    var regionMarks: [String: String] = [:]
    var groups: [Group] = []
    var mode: Mode = .rule
    var uploadRate: Int64 = 0
    var downloadRate: Int64 = 0
    /// Groups with a delay test under way; "GLOBAL" while every node is tested (`testAll`).
    var testingGroups: Set<String> = []
    /// A node switch sent to the core and not answered yet, by group: shown as selected meanwhile.
    var pendingSelections: [String: String] = [:]
    /// Why the last switch in a group failed, by group; cleared by the next switch there.
    var selectionErrors: [String: String] = [:]
    var updatingProfiles: Set<UUID> = []
    /// An action's failure, shown where the action is until the next one.
    var notice: String?

    var importText = ""
    var importing = false
    var importError: String?

    /// What the core runs with on top of the profile. The ports are picked at each start.
    var settings = ProxyStore.defaultSettings
    /// Where traffic leaves the core: shown on the Overview while it runs.
    var exit: ExitInfo?
    var showExitIP = true { didSet { if !showExitIP { exit = nil } } }
    private var exitCheck: Task<Void, Never>?
    /// Close open connections after a profile switch, a routing change or a node switch.
    var reconnectAfterChanges = true
    /// Changes gone from "my routing", for the Agent, whose conversations can still undo them.
    @ObservationIgnored var editsRemoved: (([UUID]) -> Void)?
    /// Effective configs by profile, so views and the Agent do not rebuild them on every draw.
    @ObservationIgnored private var effectiveCache: [UUID: EffectiveConfig] = [:]
    @ObservationIgnored private var effectiveRevisions: [UUID: UUID] = [:]
    /// The active profile with its "my routing" layer applied, as the core last loaded it.
    var effective: EffectiveConfig?

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var isRunning: Bool { phase == .running }
    var isStarting: Bool { phase == .starting }
    /// The select group people switch most: the first one in the config.
    var mainGroup: Group? { groups.first(where: \.isSelectable) }
    /// The core linked into the app, e.g. "v1.19.29". Static: it is part of this build.
    var coreVersion: String { core.version }

    /// This run of the core: when it started, bytes so far, the fastest second, open connections.
    var runningSince: Date?
    var uploadTotal: Int64 = 0
    var downloadTotal: Int64 = 0
    var uploadPeak: Int64 = 0
    var downloadPeak: Int64 = 0
    var connectionCount = 0

    /// Live connections, newest first, while the Connections screen is open (`watchConnections`).
    var connections: [ConnectionRow] = []
    /// The Connections screen's pause: the list stops following the core.
    var connectionsPaused = false
    /// Recently closed connections, newest first, at most `requestLimit`; in memory only.
    var requests: [ClosedRequest] = []
    static let requestLimit = 1000
    /// The core's log while it runs, oldest first, at most `logLimit` lines.
    var logs: [LogEntry] = []
    var logsPaused = false
    static let logLimit = 2000

    // MARK: Dependencies

    let paths: VeerPaths
    let profileStore: ProfileStore
    let routingStore: RoutingStore
    let core: any ProxyCore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var controller: MihomoController?
    /// The running core's controller port and secret, kept for reloads.
    @ObservationIgnored private var controllerAccess: (port: Int, secret: String)?
    /// The mixed (HTTP + SOCKS) port the running core listens on, on 127.0.0.1.
    private(set) var proxyPort: Int?
    @ObservationIgnored let runtimeLifecycle = CoreLifecycle()
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var connectionsTask: Task<Void, Never>?
    @ObservationIgnored private var lastTotals: (upload: Int64, download: Int64)?
    @ObservationIgnored private var lastConnectionBytes: [String: (upload: Int64, download: Int64)] = [:]
    @ObservationIgnored private var previousConnections: [String: ConnectionRow] = [:]
    @ObservationIgnored private var connectionsVisible = false
    /// The running core's in-place rule sets, and the rule lines each holds since the last full
    /// build (see `HotRuleSets`); nil before the core starts, or when they could not be written.
    @ObservationIgnored var hotSets: HotRuleSets?
    @ObservationIgnored var hotLines: [String: [String]] = [:]

    enum Keys {
        static let activeProfile = "activeProfile"
        static let mode = "mode"
    }

    /// Loopback only, no TUN, no process lookup (an iPhone app can't see other processes; in the
    /// Simulator it would see the Mac's).
    static var defaultSettings: RuntimeSettings {
        var settings = RuntimeSettings()
        settings.allowLAN = false
        settings.tun = false
        settings.processMatching = false
        return settings
    }

    /// Reads what is on disk and nothing else: no core, no network, no writes.
    /// `ProfileStore` makes the one secret store (`VeerPaths.makeSecretStore()`); `AgentStore` shares it.
    init(paths: VeerPaths = VeerPaths(), core: any ProxyCore = MihomoInProcessCore.shared, defaults: UserDefaults = .standard, secrets: KeyStoring? = nil) {
        self.paths = paths
        self.core = core
        self.defaults = defaults
        profileStore = ProfileStore(paths: paths, secrets: secrets)
        routingStore = RoutingStore(paths: paths)
        profiles = profileStore.loadAll()
        activeProfileID = defaults.string(forKey: Keys.activeProfile).flatMap(UUID.init(uuidString:))
            .flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles.first?.id
        regionMarks = activeProfileID.map { routingStore.load($0).regionMarks } ?? [:]
    }

    /// Where a node of the active profile exits, as an ISO code: the user's mark, else its name.
    func region(of node: String) -> String? { regionMarks[node] ?? NodeLocator.locate(node) }

    // MARK: Core

    /// Validate before starting; the editor may still open damaged groups for repair.
    private func startableText(of id: UUID) async throws -> String {
        let text = try await effectiveTextInBackground(of: id)
        try await Task.detached { try ConfigDocument.requireGroupMembers(in: text) }.value
        return text
    }

    /// A phase is presentation, not request identity: a later start can also be `.starting`.
    func isCurrent(_ token: CoreLifecycle.Token) -> Bool {
        runtimeLifecycle.contains(token) && activeProfileID == token.profileID
    }

    func start() {
        guard phase != .starting, phase != .running else { return }
        notice = nil
        guard let profile = activeProfile else { return }
        let token = runtimeLifecycle.begin(profileID: profile.id)
        phase = .starting
        runtimeLifecycle.enqueue { [self] in
            guard isCurrent(token) else { return }
            var mixed: Int?
            do {
                try paths.prepare()
                guard let ports = Self.twoFreePorts() else { throw EditorError(String(localized: "找不到可用的本机端口来控制内核。")) }
                let (port, mixedPort) = ports
                mixed = mixedPort
                let secret = RuntimeConfig.makeSecret()
                let text = try await startableText(of: profile.id)
                guard isCurrent(token) else { return }
                let hot = try await launchCore(text: text, port: port, mixedPort: mixedPort, secret: secret, token: token)
                // Stop is queued behind this operation; it alone drains and stops a stale start.
                guard isCurrent(token) else { return }
                let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
                let version = try? await controller.version()
                guard isCurrent(token) else { return }
                guard version != nil else { throw ProxyCoreError(message: "external controller did not answer") }
                hotSets = hot
                hotLines = [:]
                self.controller = controller
                controllerAccess = (port, secret)
                proxyPort = mixedPort
                await coreDidStart(token)
            } catch {
                // This operation owns the FIFO until cleanup finishes. It cannot stop a later run.
                let core = core
                await Task.detached { core.stop() }.value
                guard isCurrent(token) else { return }
                tearDownState()
                phase = .failed(failureMessage(error, port: mixed), log: failureLog(error))
            }
        }
    }

    /// The controller and the mixed port, both free now and different.
    private static func twoFreePorts() -> (Int, Int)? {
        for _ in 0..<5 {
            if let first = Ports.free(), let second = Ports.free(), first != second { return (first, second) }
        }
        return nil
    }

    /// Writes the runtime config, with its hot rule sets, and starts the in-process core. The core
    /// blocks until its controller answers (up to ~5 s), so the call runs off the main actor.
    private func launchCore(text: String, port: Int, mixedPort: Int, secret: String, token: CoreLifecycle.Token) async throws -> HotRuleSets? {
        var built = settings
        built.mixedPort = mixedPort
        let path = paths.runtimeConfig, home = paths.core, core = core
        let hot = await HotRuleSets.prepared(for: text, writer: hotWriter())
        guard isCurrent(token) else { return nil }
        try await Task.detached(priority: .userInitiated) { [built] in
            let yaml = try LoopbackRuntime.harden(RuntimeConfig.build(profile: text, settings: built, controllerPort: port, secret: secret, hot: hot))
            try Data(yaml.utf8).write(to: path, options: .atomic)
            try core.start(home: home, config: path)
        }.value
        return hot
    }

    /// The core answers: what watches it starts, and the mode chosen last time comes back.
    private func coreDidStart(_ token: CoreLifecycle.Token) async {
        guard isCurrent(token) else { return }
        phase = .running
        runningSince = .now
        await refresh()
        // refresh suspends: stop/profile activation must not resurrect these observers.
        guard isCurrent(token), isRunning else { return }
        if let saved = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)), saved != mode { setMode(saved) }
        resumeObservers(token)
    }

    private func resumeObservers(_ token: CoreLifecycle.Token) {
        guard isCurrent(token), isRunning else { return }
        startTraffic()
        startLogs()
        trackConnections()
        recheckExit()
        testAll()
    }

    /// "Address already in use" becomes the port message the copy asks for; anything else is the
    /// core's own text.
    private func failureMessage(_ error: Error, port: Int?) -> String {
        let text = message(for: error)
        if let port, text.localizedCaseInsensitiveContains("address already in use") || text.localizedCaseInsensitiveContains("mixed-port") {
            return String(localized: "内核无法使用本机端口 \(String(port))，请重新打开 Veer。")
        }
        return text
    }

    /// For the failed card's log box: the core's error as it came, then the last log lines.
    private func failureLog(_ error: Error) -> [String] {
        let own = message(for: error).split(separator: "\n").map(String.init)
        return Array((logs.suffix(6).map(\.message) + own).suffix(12))
    }

    /// Stops the core and everything watching it. The UI shows Stopped at once; the core closes
    /// its listeners in the background (`settle()` waits for that).
    func stop() {
        runtimeLifecycle.invalidate()
        tearDownState()
        phase = .stopped
        let core = core
        runtimeLifecycle.enqueue {
            await Task.detached { core.stop() }.value
        }
    }

    /// Stops and starts again with the current profile.
    func restart() {
        guard isRunning || phase.isFailed else { return start() }
        stop()
        start()
    }

    /// Waits until the last start or stop has finished with the core (for tests and app exit).
    func settle() async { await runtimeLifecycle.settle() }

    private func cancelObservers() {
        trafficTask?.cancel()
        logTask?.cancel()
        connectionsTask?.cancel()
        exitCheck?.cancel()
        exitCheck = nil
    }

    private func tearDownState() {
        cancelObservers()
        connections = []
        previousConnections = [:]
        lastConnectionBytes = [:]
        hotSets = nil
        hotLines = [:]
        controller = nil
        controllerAccess = nil
        proxyPort = nil
        groups = []
        pendingSelections = [:]
        selectionErrors = [:]
        testingGroups = []
        uploadRate = 0
        downloadRate = 0
        connectionCount = 0
        lastTotals = nil
        exit = nil
    }

    // MARK: Running core

    func refresh() async {
        guard let controller, let token = runtimeLifecycle.current, isCurrent(token) else { return }
        do {
            let proxies = try await controller.proxies()
            guard isCurrent(token) else { return }
            // GLOBAL lists every policy in config order; the dictionary has none.
            let order = proxies["GLOBAL"]?.all ?? proxies.keys.sorted()
            groups = order.compactMap { proxies[$0] }.filter { $0.isGroup && $0.hidden != true }.map { group in
                Group(name: group.name, type: group.type, now: group.now, members: (group.all ?? []).map { name in
                    // A policy that blocks can't answer a delay test, and isn't timing out.
                    Group.Member(name: name, delay: ["REJECT", "REJECT-DROP", "PASS"].contains(name) ? nil : proxies[name]?.lastDelay,
                                 isGroup: proxies[name]?.isGroup == true)
                })
            }
            let currentMode = try await controller.mode()
            guard isCurrent(token) else { return }
            if let mode = Mode(rawValue: currentMode.lowercased()) { self.mode = mode }
        } catch {
            guard isCurrent(token) else { return }
            notice = message(for: error)
        }
    }

    /// The member a group shows as selected: the switch under way, else the core's choice.
    func selectedMember(of group: Group) -> String? { pendingSelections[group.name] ?? group.now }

    /// Switches at once in the list; when the core refuses, the old node comes back and the
    /// reason stays in `selectionErrors[group]`.
    func select(_ member: String, in group: String) {
        guard let controller, let token = runtimeLifecycle.current, isCurrent(token), groups.first(where: { $0.name == group })?.isSelectable == true else { return }
        selectionErrors[group] = nil
        pendingSelections[group] = member
        Task {
            do {
                try await controller.select(member, in: group)
                guard isCurrent(token) else { return }
                await closeConnections(through: group)
            } catch {
                guard isCurrent(token) else { return }
                selectionErrors[group] = message(for: error)
            }
            guard isCurrent(token) else { return }
            await refresh()
            guard isCurrent(token) else { return }
            if pendingSelections[group] == member { pendingSelections[group] = nil }
            checkExit(after: .milliseconds(500))
        }
    }

    func isTesting(_ group: String) -> Bool { testingGroups.contains(group) || testingGroups.contains("GLOBAL") }
    var isTestingAll: Bool { testingGroups.contains("GLOBAL") }

    func testDelay(_ group: String) {
        guard let controller, let token = runtimeLifecycle.current, isCurrent(token), !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        Task {
            do { _ = try await controller.testDelay(group: group) } catch {
                guard isCurrent(token) else { return }
                notice = String(localized: "“\(group)”测速失败：\(message(for: error))")
            }
            guard isCurrent(token) else { return }
            testingGroups.remove(group)
            await refresh()
        }
    }

    /// One delay test of every node ("测速全部"; also once after each start). GLOBAL lists every
    /// node and group.
    func testAll() {
        guard let controller, let token = runtimeLifecycle.current, isCurrent(token), !testingGroups.contains("GLOBAL") else { return }
        testingGroups.insert("GLOBAL")
        Task {
            _ = try? await controller.testDelay(group: "GLOBAL")
            guard isCurrent(token) else { return }
            testingGroups.remove("GLOBAL")
            await refresh()
        }
    }

    /// The embedded controller refuses PATCH /configs, so the mode is set on the core itself.
    private func applyMode(_ mode: Mode) async throws {
        let core = core, raw = mode.rawValue
        try await Task.detached(priority: .userInitiated) { try core.setMode(raw) }.value
    }

    func setMode(_ mode: Mode) {
        guard controller != nil, let token = runtimeLifecycle.current, isCurrent(token) else { self.mode = mode; return }
        Task {
            do {
                try await applyMode(mode)
                guard isCurrent(token) else { return }
                self.mode = mode
                defaults.set(mode.rawValue, forKey: Keys.mode)
                checkExit(after: .milliseconds(500))
            } catch {
                guard isCurrent(token) else { return }
                notice = message(for: error)
            }
        }
    }

    /// A large group's nodes by region, in the order regions first appear; unknown last. Nil when
    /// the group has `threshold` nodes or fewer, which the list shows as they are.
    func regionSections(of group: Group, threshold: Int = 12) -> [RegionSection]? {
        let nodes = group.members.filter(\.isNode)
        guard nodes.count > threshold else { return nil }
        var order: [String?] = []
        var byRegion: [String?: [Group.Member]] = [:]
        for node in nodes {
            let code = region(of: node.name)
            if byRegion[code] == nil { order.append(code) }
            byRegion[code, default: []].append(node)
        }
        order = order.filter { $0 != nil } + order.filter { $0 == nil }
        return order.map { RegionSection(code: $0, members: byRegion[$0] ?? []) }
    }

    private func startTraffic() {
        guard let token = runtimeLifecycle.current, isCurrent(token) else { return }
        trafficTask?.cancel()
        lastTotals = nil
        uploadTotal = 0
        downloadTotal = 0
        uploadPeak = 0
        downloadPeak = 0
        trafficTask = Task {
            while !Task.isCancelled, isCurrent(token), let controller {
                if let totals = try? await controller.trafficSnapshot() {
                    guard !Task.isCancelled, isCurrent(token) else { return }
                    if let last = lastTotals {
                        uploadRate = max(0, totals.upload - last.upload)
                        downloadRate = max(0, totals.download - last.download)
                        uploadPeak = max(uploadPeak, uploadRate)
                        downloadPeak = max(downloadPeak, downloadRate)
                    }
                    lastTotals = (totals.upload, totals.download)
                    uploadTotal = totals.upload
                    downloadTotal = totals.download
                    connectionCount = totals.connections
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Loads the active profile into the running core without restarting it. With
    /// `closingConnections` (a new profile or new rules), open connections are closed: the core
    /// keeps routing them the old way until they reconnect.
    func reloadRunningCore(closingConnections: Bool = false) async {
        guard let token = runtimeLifecycle.current else { return }
        await enqueueReload(token, closingConnections: closingConnections).value
    }

    /// Submission happens synchronously at the request site, not inside a later unstructured task.
    @discardableResult
    private func enqueueReload(_ token: CoreLifecycle.Token, closingConnections: Bool) -> Task<Void, Never> {
        runtimeLifecycle.enqueue { [self] in
            await reloadCore(token, closingConnections: closingConnections)
        }
    }

    /// Only call from inside the mutation FIFO (hot-update fallback must not enqueue and deadlock).
    func reloadCore(_ token: CoreLifecycle.Token, closingConnections: Bool) async {
        guard isCurrent(token), isRunning, let controller, let access = controllerAccess, let mixed = proxyPort else { return }
        do {
            var running = settings
            running.mixedPort = mixed
            let text = try await effectiveTextInBackground(of: token.profileID)
            guard isCurrent(token) else { return }
            let path = paths.runtimeConfig, port = access.port, secret = access.secret, built = running
            let hot = await HotRuleSets.prepared(for: text, writer: hotWriter())
            guard isCurrent(token) else { return }
            let yaml = try await Task.detached(priority: .userInitiated) { () -> String in
                let yaml = try LoopbackRuntime.harden(RuntimeConfig.build(profile: text, settings: built, controllerPort: port, secret: secret, hot: hot))
                try Data(yaml.utf8).write(to: path, options: .atomic)
                return yaml
            }.value
            guard isCurrent(token) else { return }
            // The embedded controller has no PUT /configs; the core re-reads the file just written.
            _ = yaml
            let core = core
            try await Task.detached(priority: .userInitiated) { try core.reload(config: path) }.value
            guard isCurrent(token) else { return }
            hotSets = hot
            hotLines = [:]
            if closingConnections && reconnectAfterChanges {
                try? await controller.closeAllConnections()
                guard isCurrent(token) else { return }
            }
            await refresh()
        } catch {
            guard isCurrent(token) else { return }
            notice = message(for: error)
        }
    }

    // MARK: Exit IP

    /// Asks public IP services, through the core's own mixed port, where traffic leaves, until one
    /// answers or `ExitProbe` runs out of time. Runs again after a node or mode switch.
    func checkExit(after delay: Duration = .zero) {
        exitCheck?.cancel()
        guard showExitIP, isRunning, let port = proxyPort, let token = runtimeLifecycle.current, isCurrent(token) else { exit = nil; exitCheck = nil; return }
        // A failure is not the answer to a new question; what is known stays until it is replaced.
        if exit == .unknown { exit = nil }
        exitCheck = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, isCurrent(token) else { return }
            let found = await ExitProbe.run { await ExitInfo.lookUp(throughPort: port) }
            guard !Task.isCancelled, isCurrent(token) else { return }
            exit = found ?? ExitInfo.unknown
            exitCheck = nil
        }
    }

    /// The person asked: back to detecting, so the screen shows that something is happening.
    func recheckExit() {
        exit = nil
        checkExit()
    }

    /// True while a check runs and nothing is known yet ("正在检测…").
    var isCheckingExit: Bool { exit == nil && exitCheck != nil }

    // MARK: Connections and logs

    /// The Connections screen shows live rows only while it is open.
    func watchConnections(_ on: Bool) {
        connectionsVisible = on
        if !on { connections = [] }
    }

    /// Polls `/connections` every second while the core runs: closed connections become
    /// requests, and the Connections screen gets its rows while it is open.
    private func trackConnections() {
        guard let token = runtimeLifecycle.current, isCurrent(token) else { return }
        connectionsTask?.cancel()
        previousConnections = [:]
        connectionsTask = Task {
            while !Task.isCancelled, isCurrent(token) {
                if let controller, let list = try? await controller.connections() {
                    guard !Task.isCancelled, isCurrent(token) else { return }
                    var rows: [ConnectionRow] = []
                    var bytes: [String: (Int64, Int64)] = [:]
                    for connection in list {
                        let last = lastConnectionBytes[connection.id]
                        rows.append(ConnectionRow(connection, uploadRate: last.map { max(0, connection.upload - $0.upload) } ?? 0,
                                                  downloadRate: last.map { max(0, connection.download - $0.download) } ?? 0))
                        bytes[connection.id] = (connection.upload, connection.download)
                    }
                    lastConnectionBytes = bytes.mapValues { (upload: $0.0, download: $0.1) }
                    recordClosed(now: rows)
                    if connectionsVisible, !connectionsPaused {
                        connections = rows.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Connections in the last poll but not in this one have closed.
    private func recordClosed(now rows: [ConnectionRow], at time: Date = .now) {
        let current = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let closed = previousConnections.values.filter { current[$0.id] == nil }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            .map { ClosedRequest(row: $0, closedAt: time) }
        previousConnections = current
        guard !closed.isEmpty else { return }
        requests.insert(contentsOf: closed, at: 0)
        if requests.count > Self.requestLimit { requests.removeLast(requests.count - Self.requestLimit) }
    }

    func clearRequests() { requests = [] }

    /// What Undo brings back, behind anything that has ended since, up to the usual limit.
    func restoreRequests(_ saved: [ClosedRequest]) { requests = Array((requests + saved).prefix(Self.requestLimit)) }

    /// After a node switch: connections that went through `group` keep their old node until they
    /// reconnect, so they are closed.
    func closeConnections(through group: String) async {
        guard reconnectAfterChanges, let controller, let token = runtimeLifecycle.current,
              isCurrent(token), let list = try? await controller.connections() else { return }
        for connection in list where connection.chains.contains(group) {
            guard isCurrent(token) else { return }
            try? await controller.closeConnection(connection.id)
        }
    }

    func closeConnection(_ id: String) {
        guard let controller else { return }
        Task {
            do { try await controller.closeConnection(id) } catch { notice = message(for: error) }
            connections.removeAll { $0.id == id }
        }
    }

    func closeAllConnections() {
        guard let controller else { return }
        Task {
            do { try await controller.closeAllConnections() } catch { notice = message(for: error) }
            connections = []
        }
    }

    /// Streams the core's log for as long as it runs.
    private func startLogs() {
        logTask?.cancel()
        guard let controller, let token = runtimeLifecycle.current, isCurrent(token) else { return }
        let level = settings.logLevel
        logTask = Task {
            do {
                for try await line in controller.logs(level: level) {
                    guard !Task.isCancelled, isCurrent(token) else { return }
                    guard !logsPaused else { continue }
                    logs.append(LogEntry(level: line.type, message: line.payload))
                    if logs.count > Self.logLimit { logs.removeFirst(logs.count - Self.logLimit) }
                }
            } catch {}
        }
    }

    func clearLogs() { logs = [] }

    /// What Undo brings back, before anything logged since, up to the usual limit.
    func restoreLogs(_ saved: [LogEntry]) { logs = Array((saved + logs).suffix(Self.logLimit)) }

    // MARK: Agent actions on the running core

    private func runningController() throws -> MihomoController {
        guard isRunning, let controller else { throw EditorError(String(localized: "内核没有运行，先启动内核。")) }
        return controller
    }

    /// The group as the core reports it now.
    func liveGroup(_ name: String) async throws -> Group {
        _ = try runningController()
        await refresh()
        guard let group = groups.first(where: { $0.name == name }) else {
            throw EditorError(String(localized: "运行中的内核里没有策略组“\(name)”。"))
        }
        return group
    }

    /// Selects `node` in a select group; returns the node it replaced.
    @discardableResult func choose(_ node: String, in name: String) async throws -> String? {
        let controller = try runningController()
        let group = try await liveGroup(name)
        guard group.isSelectable else { throw EditorError(String(localized: "“\(name)”按延迟自动选择，不能手动切换节点。")) }
        let previous = group.now
        try await controller.select(node, in: name)
        await closeConnections(through: name)
        await refresh()
        checkExit(after: .milliseconds(500))
        return previous
    }

    /// Tests every member's delay; 0 means it timed out.
    func testNow(_ name: String) async throws -> [String: Int] {
        let controller = try runningController()
        let result = try await controller.testDelay(group: name)
        await refresh()
        return result
    }

    /// Switches the mode; returns the one it replaced.
    @discardableResult func switchMode(_ mode: Mode) async throws -> Mode {
        _ = try runningController()
        let previous = self.mode
        try await applyMode(mode)
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Keys.mode)
        checkExit(after: .milliseconds(500))
        return previous
    }

    /// Closes connections to `host` and its subdomains; returns how many.
    func closeConnections(host: String) async throws -> Int {
        let controller = try runningController()
        let matching = try await controller.connections().filter { connection in
            guard let name = connection.metadata.host?.lowercased(), !name.isEmpty else { return false }
            return name == host || name.hasSuffix("." + host)
        }
        for connection in matching { try? await controller.closeConnection(connection.id) }
        return matching.count
    }

    /// How the core routed its current connections to `domains`, in words, for the AI to explain
    /// a route with facts. Nil when the core is not running or nothing matched.
    func connectionSummary(for domains: [String]) async -> String? {
        guard isRunning, let controller, let connections = try? await controller.connections() else { return nil }
        var lines: [String] = []
        for domain in domains.prefix(8) {
            let host = domain.lowercased()
            let matching = connections.filter { ($0.metadata.host?.lowercased()).map { $0 == host || $0.hasSuffix("." + host) } ?? false }
            var seen = Set<String>()
            for connection in matching {
                let rule = connection.rulePayload.isEmpty ? connection.rule : "\(connection.rule),\(connection.rulePayload)"
                let line = "\(connection.metadata.host ?? host)：命中 \(rule)，代理链 \(connection.chains.reversed().joined(separator: " → "))"  // for the AI
                if seen.insert(line).inserted { lines.append("· " + line) }
                if seen.count >= 3 { break }
            }
        }
        // Connections that already closed still show in the log: "x.com:443 match RuleSet(X) using Group[Node]".
        var logged: [String] = []
        for domain in domains.prefix(8) {
            let host = domain.lowercased()
            let hits = logs.reversed().filter { entry in
                let text = entry.message.lowercased()
                return text.contains(" match ") && (text.contains("--> \(host):") || text.contains(".\(host):"))
            }
            for entry in hits.prefix(2) {
                if let range = entry.message.range(of: "-->") { logged.append("· " + entry.message[range.upperBound...].trimmingCharacters(in: .whitespaces)) }
            }
        }
        guard !lines.isEmpty || !logged.isEmpty else { return nil }
        var summary: [String] = []
        if !lines.isEmpty { summary.append("运行中内核的真实连接（最近）：\n" + lines.joined(separator: "\n")) }  // for the AI
        if !logged.isEmpty { summary.append("内核日志里的路由记录（最近，格式：主机:端口 match 规则 using 策略组[节点]）：\n" + logged.joined(separator: "\n")) }  // for the AI
        return summary.joined(separator: "\n\n")
    }

    // MARK: My routing

    /// The profile with its layer applied; kept in `effective` for the active one.
    func effectiveText(of id: UUID) throws -> String {
        if let cached = effectiveCache[id] { return cached.text }
        let result = try routingStore.load(id).apply(to: try profileStore.text(of: id))
        remember(result, for: id)
        return result.text
    }

    /// The same, built off the main thread.
    func effectiveTextInBackground(of id: UUID) async throws -> String {
        if let cached = effectiveCache[id] { return cached.text }
        let routingStore = routingStore, profileStore = profileStore
        let token = runtimeLifecycle.current
        let revision = effectiveRevisions[id]
        let result = try await Task.detached(priority: .userInitiated) {
            try routingStore.load(id).apply(to: try profileStore.text(of: id))
        }.value
        if token == runtimeLifecycle.current, revision == effectiveRevisions[id] {
            remember(result, for: id)
        }
        return result.text
    }

    private func remember(_ result: EffectiveConfig, for id: UUID) {
        effectiveCache[id] = result
        if id == activeProfileID { effective = result }
    }

    /// The profile's text or layer changed: its effective config has to be built again.
    private func forgetEffective(_ id: UUID) {
        effectiveRevisions[id] = UUID()
        effectiveCache[id] = nil
        if id == activeProfileID { effective = nil }
    }

    func layer(of id: UUID) -> RoutingLayer { routingStore.load(id) }

    /// Adds an applied change; false (with a notice) when it could not be saved.
    @discardableResult func addEdit(_ edit: RoutingLayer.Edit, to id: UUID) -> Bool {
        var layer = routingStore.load(id)
        layer.edits.append(edit)
        // Routes alone go into the running core's hot rule sets: no reload, other connections kept.
        if id == activeProfileID, isRunning, let entries = hotEntries(for: edit) {
            do { try routingStore.save(layer, for: id) } catch {
                notice = message(for: error)
                return false
            }
            forgetEffective(id)
            hotUpdate = enqueueHot(entries, profile: id)
            return true
        }
        return saveLayer(layer, for: id)
    }

    /// The last hot update or reload started by an edit, for tests to wait on.
    @ObservationIgnored var hotUpdate: Task<Void, Never>?

    /// False when the change has gone.
    @discardableResult func setEdit(_ editID: UUID, enabled: Bool, in id: UUID) -> Bool {
        var layer = routingStore.load(id)
        guard let index = layer.edits.firstIndex(where: { $0.id == editID }) else { return false }
        layer.edits[index].enabled = enabled
        saveLayer(layer, for: id)
        return true
    }

    func deleteEdit(_ editID: UUID, in id: UUID) {
        var layer = routingStore.load(id)
        layer.edits.removeAll { $0.id == editID }
        saveLayer(layer, for: id)
        editsRemoved?([editID])
    }

    @discardableResult private func saveLayer(_ layer: RoutingLayer, for id: UUID) -> Bool {
        do {
            try routingStore.save(layer, for: id)
            forgetEffective(id)
            if id == activeProfileID {
                if isRunning, let token = runtimeLifecycle.current {
                    hotUpdate = enqueueReload(token, closingConnections: true)
                } else {
                    hotUpdate = Task { _ = try? await effectiveTextInBackground(of: id) }
                }
            }
            return true
        } catch {
            notice = message(for: error)
            return false
        }
    }

    // MARK: Profiles

    func activate(_ id: UUID) {
        guard id != activeProfileID else { return }
        let wasStarting = isStarting
        activeProfileID = id
        effective = effectiveCache[id]
        if wasStarting {
            // The pending start owns a different profile. Drain it before starting this one.
            stop()
            start()
        } else if isRunning {
            let token = runtimeLifecycle.begin(profileID: id)
            cancelObservers()
            pendingSelections = [:]
            selectionErrors = [:]
            testingGroups = []
            hotSets = nil
            hotLines = [:]
            runtimeLifecycle.enqueue { [self] in
                await reloadCore(token, closingConnections: true)
                resumeObservers(token)
            }
        } else if case .failed = phase { start() }
    }

    func delete(_ id: UUID) {
        if id == activeProfileID {
            stop()
            activeProfileID = profiles.first { $0.id != id }?.id
        }
        let edits = routingStore.load(id).edits.map(\.id)
        profileStore.delete(id)
        routingStore.delete(id)
        forgetEffective(id)
        editsRemoved?(edits)
        profiles = profileStore.loadAll()
    }

    /// The Import sheet opens with `prefill` (for example the clipboard) and no old error.
    func openImport(prefill: String = "") {
        importText = prefill
        importError = nil
    }

    /// A subscription link, or pasted config / share links, from `importText`. True when a
    /// profile was added (the sheet closes); otherwise `importError` says why.
    @discardableResult func importFromText() async -> Bool {
        let input = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !importing else { return false }
        importing = true
        importError = nil
        defer { importing = false }
        do {
            if SubscriptionFetcher.looksLikeLink(input) {
                let url = try SubscriptionFetcher.validate(input)
                let response = try await fetchSubscription(url)
                let result = try ConfigImporter.normalize(response.text)
                var profile = Profile(name: response.title ?? url.host() ?? String(localized: "订阅"), isSubscription: true,
                                      nodeCount: result.nodeCount, usage: response.usage)
                profile.updateIntervalHours = response.updateIntervalHours
                try profileStore.save(profile, text: result.text)
                try profileStore.setSubscriptionURL(url, for: profile.id)
                added(profile)
            } else {
                let result = try ConfigImporter.normalize(input)
                let profile = Profile(name: String(localized: "粘贴的配置"), isSubscription: false, nodeCount: result.nodeCount)
                try profileStore.save(profile, text: result.text)
                added(profile)
            }
            importText = ""
            return true
        } catch {
            importError = message(for: error)
            return false
        }
    }

    /// A Mihomo / Clash file from Files (`.fileImporter` gives a security-scoped URL). The
    /// profile takes the file's name. True when added; otherwise `importError` says why.
    @discardableResult func importFile(_ url: URL) -> Bool {
        importError = nil
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try ConfigImporter.normalize(text)
            let profile = Profile(name: url.deletingPathExtension().lastPathComponent, isSubscription: false, nodeCount: result.nodeCount)
            try profileStore.save(profile, text: result.text)
            added(profile)
            return true
        } catch {
            importError = message(for: error)
            return false
        }
    }

    private func added(_ profile: Profile) {
        profiles = profileStore.loadAll()
        if activeProfileID == nil { activeProfileID = profile.id }
    }

    /// Whether the profile has a subscription link to update from.
    func canUpdate(_ id: UUID) -> Bool { profileStore.subscriptionURL(of: id) != nil }

    /// Downloads a subscription again; a failure is reported as a notice.
    func update(_ id: UUID) {
        guard let url = profileStore.subscriptionURL(of: id), var profile = profiles.first(where: { $0.id == id }), !updatingProfiles.contains(id) else { return }
        updatingProfiles.insert(id)
        notice = nil
        Task {
            defer { updatingProfiles.remove(id) }
            do {
                let response = try await fetchSubscription(url)
                let result = try ConfigImporter.normalize(response.text)
                profile.nodeCount = result.nodeCount
                profile.updatedAt = .now
                profile.usage = response.usage ?? profile.usage
                profile.updateIntervalHours = response.updateIntervalHours ?? profile.updateIntervalHours
                profile.updateError = nil
                try profileStore.save(profile, text: result.text)
                forgetEffective(id)
                profiles = profileStore.loadAll()
                if id == activeProfileID { await reloadRunningCore(closingConnections: true) }
            } catch {
                notice = String(localized: "“\(profile.name)”更新失败：\(message(for: error))")
            }
        }
    }

    /// Straight out first, so a broken node cannot stop an update; through the running core
    /// when that fails.
    private func fetchSubscription(_ url: URL) async throws -> SubscriptionResponse {
        do {
            return try await SubscriptionFetcher(route: .direct).fetch(url)
        } catch {
            guard isRunning, let port = proxyPort else { throw error }
            return try await SubscriptionFetcher(route: .proxy(port: port)).fetch(url)
        }
    }

    func message(for error: Error) -> String {
        (error as? EditorError)?.message ?? error.localizedDescription
    }
}
