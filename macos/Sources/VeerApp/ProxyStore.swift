import AppKit
import Foundation
import Network
import Observation
import VeerCore
import VeerProxy

/// Everything the windows and the menu bar show about the proxy, and the actions on it.
/// First-run steps: add a subscription, choose how to route, turn the proxy on.
enum OnboardingStep: Int, CaseIterable {
    case addProfile, routing, start
}

@Observable
final class ProxyStore {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        /// Why the core could not start or stopped on its own, with its last output lines.
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
            /// What Veer knows of its delay in the running profile (`LatencyTest`).
            let state: NodeDelay
            var id: String { name }

            init(name: String, delay: Int?, isGroup: Bool, state: NodeDelay? = nil) {
                self.name = name
                self.isGroup = isGroup
                self.state = state ?? NodeDelay(history: delay)
                self.delay = state?.legacyDelay ?? delay
            }
        }

        let name: String
        let type: String
        let now: String?
        let members: [Member]
        var id: String { name }
        var isSelectable: Bool { type == "Selector" }
    }

    // MARK: State

    var page: Page = .overview
    /// A destination for the route tester to check when it opens, from another page; it takes it once.
    var routeTestRequest: RouteTestRequest?
    /// Where the Agent shows beside the pages: nowhere, docked as the panel (`AgentPanel`), or in a
    /// window of its own (`AgentWindow`). The window and the panel show one conversation from one
    /// `AgentStore`, so a move between them carries everything across. Saved, with the last place shown.
    var agentPresentation: AgentPresentation {
        didSet {
            guard agentPresentation != oldValue else { return }
            defaults.set(agentPresentation.rawValue, forKey: "agentPresentation")
            // For a version from before the window, which reads only this.
            defaults.set(agentPresentation == .docked, forKey: "agentPanel")
            if agentPresentation != .hidden { lastAgentPresentation = agentPresentation }
        }
    }
    /// What the toolbar's Agent button brings back: the panel or the window.
    var lastAgentPresentation: AgentPresentation { didSet { defaults.set(lastAgentPresentation.rawValue, forKey: "lastAgentPresentation") } }
    /// The Agent beside every page but its own (`AgentPanel`). Open until the user closes it.
    var agentPanel: Bool {
        get { agentPresentation == .docked }
        // Closing the panel leaves a window alone: only the window's own actions close it.
        set { if newValue { agentPresentation = .docked } else if agentPresentation == .docked { agentPresentation = .hidden } }
    }
    /// Opens the Agent's window, or brings it forward, and the main window. Set by a view that can
    /// reach `openWindow` (`MenuBarLabel`); a store cannot.
    @ObservationIgnored var openAgentWindow: () -> Void = {}
    @ObservationIgnored var openMainWindow: () -> Void = {}
    /// Its width, which the user drags.
    var agentPanelWidth: Double { didSet { defaults.set(agentPanelWidth, forKey: "agentPanelWidth") } }
    var phase: Phase = .stopped {
        didSet {
            if phase == .starting { runningCoreRevision = coreRevision }
            // The proxy must not point at a core that failed: every app would lose the network. A
            // restart on its own can get here, with no one watching. It comes back with the next start.
            if case .failed = phase, systemProxyOn {
                setSystemProxy(false, remember: false)
                systemProxyIsFallback = false
            }
        }
    }
    var profiles: [Profile] = []
    var activeProfileID: UUID? {
        didSet {
            defaults.set(activeProfileID?.uuidString, forKey: "activeProfile")
            regionMarks = activeProfileID.map { routingStore.load($0).regionMarks } ?? [:]
        }
    }
    /// The active profile's hand-set node regions, by node name.
    var regionMarks: [String: String] = [:]
    /// Regions read from servers' addresses, for nodes whose names say nothing (`ServerRegions`).
    var ipRegions: [String: String] = [:]
    @ObservationIgnored private var ipRegionTask: Task<Void, Never>?
    var groups: [Group] = []
    var mode: Mode = .rule
    var systemProxyOn = false
    /// The core runs as root through the helper with a TUN device.
    var tunActive = false
    /// Where the privileged helper stands, as last checked; nil before the first check.
    var helperState: HelperState?
    /// How the helper's state is read; snapshots replace it.
    @ObservationIgnored var helperProbe: () async -> HelperState = { await HelperClient.shared.state() }
    var helperBusy = false
    var uploadRate: Int64 = 0
    var downloadRate: Int64 = 0
    var testingScopes: Set<LatencyScope> = []
    /// Each node's delay as Veer tested it in the running profile; cleared with every new profile.
    /// Not observed: views read a node's `NodeDelayCell`, summaries `delayRevision`, so one result
    /// redraws what shows that node rather than every group (`ProxyStoreLatency`).
    @ObservationIgnored var delays: [String: NodeDelay] = [:]
    /// One per node shown, by name; kept in step with `delays` a few times a second.
    @ObservationIgnored var delayCells: [String: NodeDelayCell] = [:]
    /// Results recorded since the cells were last brought up to date.
    @ObservationIgnored var pendingDelayNames: Set<String> = []
    /// Bumped each time results reach the cells: for views that sum up many nodes, such as the
    /// map's regions and their lowest delays.
    var delayRevision = 0
    /// Names whose region and notice check have been read ahead (`warmNodeLookups`).
    @ObservationIgnored var warmedNodeNames: Set<String> = []
    @ObservationIgnored var delayTimes: [String: Date] = [:]
    @ObservationIgnored var latencyRuns: [LatencyScope: Task<Void, Never>] = [:]
    @ObservationIgnored var delayFlush: Task<Void, Never>?
    /// Bumped by every profile switch and core stop: work started under an older one is dropped,
    /// so a test or reload that finishes late can't write into the profile that replaced it.
    @ObservationIgnored var generation = 0
    /// What delay tests fetch through each node; tests point it at a server on this Mac.
    @ObservationIgnored var delayURL = MihomoController.delayURL
    /// Picks the controller's port for each start; tests hold a port and hand it over.
    @ObservationIgnored var pickControllerPort: () -> Int? = { Ports.free() }
    /// The profile being switched to while its config is checked and loaded.
    var switchingTo: UUID?
    @ObservationIgnored var profileAfterStartup: UUID?
    /// The profile the core runs while a switch is under way: where a failed switch goes back to.
    @ObservationIgnored var committedProfileID: UUID?
    @ObservationIgnored let coreConfigWork = SerialWork()
    /// The one subscription update or import in progress, and how the last one went.
    var activity: Activity?
    @ObservationIgnored var activityDismissal: Task<Void, Never>?
    var updatingProfiles: Set<UUID> = []
    /// An action's failure, shown where the action is until the next one.
    var notice: String?

    /// Where first-run onboarding is; nil once it is done or when there were profiles already.
    var onboarding: OnboardingStep?

    var showingImport = false
    /// Manage Profiles, the sheet every profile is switched, updated and managed from.
    var showingProfiles = false
    var importText = ""
    var importing = false
    var importError: String?

    var settings: RuntimeSettings {
        didSet {
            saveSettings()
            // TUN changes who runs the core, so the core starts again.
            if settings.tun != oldValue.tun {
                if isRunning { restart() }
                return
            }
            // The port takes effect at the next start; everything else reloads into the running core.
            var withoutPort = settings, before = oldValue
            withoutPort.mixedPort = 0
            before.mixedPort = 0
            guard isRunning, withoutPort != before else { return }
            settingsReload?.cancel()
            settingsReload = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await reloadRunningCore()
                if !Task.isCancelled, isRunning, settings.logLevel != oldValue.logLevel { startLogs() }
            }
        }
    }
    @ObservationIgnored private var settingsReload: Task<Void, Never>?
    @ObservationIgnored var updateSchedule: Task<Void, Never>?
    @ObservationIgnored var lastAutomaticUpdate: [UUID: Date] = [:]
    /// Shows a usage alert; a system notification in the app, replaced in tests.
    @ObservationIgnored var notifier: ((title: String, body: String)) -> Void = { UsageNotifier.post($0) }
    /// Effective configs by profile, so views and the Agent do not rebuild them on every draw.
    @ObservationIgnored var effectiveCache: [UUID: EffectiveConfig] = [:]
    @ObservationIgnored private var effectiveRevisions: [UUID: Int] = [:]
    /// Where traffic leaves the proxy: shown on the overview while the core runs.
    var exit: ExitInfo?
    var showExitIP: Bool { didSet { defaults.set(showExitIP, forKey: "showExitIP"); if !showExitIP { exit = nil } } }
    /// The exit check under way (`ProxyStoreExitIP.swift`).
    @ObservationIgnored var exitCheck: Task<Void, Never>?
    /// Start the core, the system proxy and the mode as they were when Veer last quit.
    var restoreLastState: Bool { didSet { defaults.set(restoreLastState, forKey: "restoreLastState") } }
    var showRateInMenuBar: Bool { didSet { defaults.set(showRateInMenuBar, forKey: "showRateInMenuBar") } }
    /// Close open connections after a profile switch, a routing change or a node switch, so they
    /// reconnect the new way instead of staying on the old route.
    var reconnectAfterChanges: Bool { didSet { defaults.set(reconnectAfterChanges, forKey: "reconnectAfterChanges") } }
    @ObservationIgnored private let systemProxyWork = SerialWork()
    /// Changes gone from "my routing", for the Agent, whose conversations can still undo them.
    @ObservationIgnored var editsRemoved: (([UUID]) -> Void)?
    /// The last "my routing" change on its way into the running core, to wait for before saying it took.
    @ObservationIgnored var layerApply: Task<LayerApplied, Never>?
    enum LayerApplied: Equatable {
        /// Saved; the core is not running this profile, so it takes it at the next start.
        case saved
        case running
        case refused(String)
    }
    /// Removed duplicate profile → the profile kept in its place, for conversations to follow.
    @ObservationIgnored var profilesMerged: (([UUID: UUID]) -> Void)?
    /// Subscription links being imported now, so the same link twice makes one profile.
    @ObservationIgnored var importingLinks: Set<String> = []
    /// On only because TUN could not start, not because anyone asked for it.
    @ObservationIgnored private var systemProxyIsFallback = false
    /// Groups folded on the Proxies page, by name; remembered across launches.
    var collapsedGroups: Set<String> { didSet { defaults.set(Array(collapsedGroups), forKey: "collapsedGroups") } }
    /// The active profile with its "my routing" layer applied, as the core last loaded it.
    var effective: EffectiveConfig?
    /// App routing's apps and state (`ProxyStoreAppRouting.swift`).
    var apps = AppRoutingState()

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var isRunning: Bool { phase == .running }
    /// The select group people switch most: the first one in the config.
    var mainGroup: Group? { groups.first(where: \.isSelectable) }

    // MARK: Dependencies

    let paths: VeerPaths
    let profileStore: ProfileStore
    let routingStore: RoutingStore
    /// Effective configs kept between launches.
    var effectiveStore: EffectiveConfigCache { EffectiveConfigCache(paths: paths) }
    let stateStore: StateStore
    let systemProxy: SystemProxy
    let binary: URL?
    /// A newer core installed from Settings, which runs in place of `binary`.
    var hasUpdatedCore: Bool
    /// Changes with each core installed or removed, for what shows its version.
    var coreRevision = 0
    /// `coreRevision` when the core running now started.
    @ObservationIgnored var runningCoreRevision = 0
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var core: CoreRunning?
    /// The latest start of the core, step by step (`StartupTimeline`); also in the diagnostics bundle.
    @ObservationIgnored var startup: StartupTimeline?
    @ObservationIgnored private(set) var controller: MihomoController?
    /// The running core's controller port and secret, kept for reloads.
    @ObservationIgnored private var controllerAccess: (port: Int, secret: String)?
    /// The port the running core listens on; a changed setting applies at the next start.
    @ObservationIgnored private var runningPort: Int?
    var proxyPort: Int { runningPort ?? settings.mixedPort }
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var connectionsTask: Task<Void, Never>?
    /// The previous poll's byte counts, for per-connection speeds.
    @ObservationIgnored private var lastConnectionBytes: [String: (upload: Int64, download: Int64)] = [:]

    /// This run of the core: when it started, bytes so far, the fastest second, open connections.
    var runningSince: Date?
    var uploadTotal: Int64 = 0
    var downloadTotal: Int64 = 0
    var uploadPeak: Int64 = 0
    var downloadPeak: Int64 = 0
    var connectionCount = 0
    var serviceDelays: [String: Int] = [:]

    /// Live connections, newest first, while the connections page is open.
    var connections: [ConnectionRow] = []
    var connectionsPaused = false
    /// Filters the Connections page takes once when it appears: snapshot scenes set them.
    @ObservationIgnored var connectionsFilterSeed: ConnectionFilters?
    /// Here rather than on the page, as the menu bar asks too.
    var confirmingCloseAllConnections = false
    /// Found on this Mac from logs, connections and delay tests; shown on the overview and Agent pages.
    var suggestions: [Suggestion] = []
    @ObservationIgnored private lazy var detector = SuggestionDetector(ignoredHosts: Set(defaults.stringArray(forKey: "ignoredSuggestionHosts") ?? []))
    /// Recently closed connections, newest first, at most `requestLimit`; in memory only.
    var requests: [ClosedRequest] = []
    static let requestLimit = 1000
    /// The connections page is open, so `connections` follows the core every second.
    @ObservationIgnored private var connectionsVisible = false
    /// The running core's in-place rule sets, and the rule lines each holds since the last full
    /// build (see `HotRuleSets`); nil before the core starts, or when they could not be written.
    @ObservationIgnored var hotSets: HotRuleSets?
    @ObservationIgnored var hotLines: [String: [String]] = [:]
    /// The previous poll's connections, to see which closed.
    @ObservationIgnored private var previousConnections: [String: ConnectionRow] = [:]
    /// Routes from the log waiting to learn whether a poll saw them.
    @ObservationIgnored private var loggedRoutes: [(row: ConnectionRow, at: Date)] = []
    /// When each host and app was last in a poll.
    @ObservationIgnored private var polledKeys: [String: Date] = [:]
    /// The core's log while it runs, oldest first, at most `logLimit` lines.
    var logs: [LogEntry] = []
    var logsPaused = false
    static let logLimit = 2000
    @ObservationIgnored private var lastTotals: (upload: Int64, download: Int64)?
    @ObservationIgnored private var state: ProxyState { didSet { if state != oldValue { stateStore.save(state) } } }
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init(paths: VeerPaths = VeerPaths(), systemProxy: SystemProxy = SystemProxy(), binary: URL? = ProxyStore.bundledCore, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.profileStore = ProfileStore(paths: paths)
        self.routingStore = RoutingStore(paths: paths)
        self.stateStore = StateStore(paths: paths)
        self.systemProxy = systemProxy
        self.binary = binary
        hasUpdatedCore = CoreUpdater(paths: paths).hasInstalled
        self.defaults = defaults
        settings = defaults.data(forKey: "runtimeSettings").flatMap { try? JSONDecoder().decode(RuntimeSettings.self, from: $0) } ?? RuntimeSettings()
        restoreLastState = defaults.object(forKey: "restoreLastState") as? Bool ?? true
        showRateInMenuBar = defaults.bool(forKey: "showRateInMenuBar")
        showExitIP = defaults.object(forKey: "showExitIP") as? Bool ?? true
        reconnectAfterChanges = defaults.object(forKey: "reconnectAfterChanges") as? Bool ?? true
        collapsedGroups = Set(defaults.stringArray(forKey: "collapsedGroups") ?? [])
        let presentation = AgentPresentation.saved(defaults.string(forKey: "agentPresentation"), panel: defaults.object(forKey: "agentPanel") as? Bool)
        agentPresentation = presentation
        lastAgentPresentation = AgentPresentation.savedLast(defaults.string(forKey: "lastAgentPresentation"), current: presentation)
        agentPanelWidth = defaults.object(forKey: "agentPanelWidth") as? Double ?? AgentPanelColumn.idealWidth
        state = stateStore.load()
        profiles = profileStore.loadAll()
        activeProfileID = defaults.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:)).flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        if profiles.isEmpty { onboarding = .addProfile }
        regionMarks = activeProfileID.map { routingStore.load($0).regionMarks } ?? [:]
    }

    /// Where a node of the active profile exits, as an ISO code: the user's mark, else its name,
    /// else its server's address.
    func region(of node: String) -> String? { regionMarks[node] ?? NodeLocator.locate(node) ?? ipRegions[node] }

    /// Whether `region(of:)` came from the server's address, which for a relay is its entry.
    func regionIsFromIP(_ node: String) -> Bool { regionMarks[node] == nil && NodeLocator.locate(node) == nil && ipRegions[node] != nil }

    /// Looks up the servers of the active profile's unrecognized nodes in the core's GeoIP
    /// database, off the main thread. Runs once the core has run (it downloads the database).
    func locateServersByIP() {
        ipRegionTask?.cancel()
        guard let id = activeProfileID, let text = try? profileStore.text(of: id) else { ipRegions = [:]; return }
        let marks = regionMarks, home = paths.core
        ipRegionTask = Task {
            let found = await Task.detached(priority: .utility) { () -> [String: String] in
                guard let database = ServerRegions.database(in: home) else { return [:] }
                let servers = ServerRegions.servers(in: text)
                let unknown = servers.keys.filter { marks[$0] == nil && NodeLocator.locate($0) == nil && !NodeCleanup.isInfoNode($0) }.sorted()
                return ServerRegions.locate(unknown, servers: servers, database: database)
            }.value
            guard !Task.isCancelled, id == activeProfileID else { return }
            ipRegions = found
        }
    }

    /// Sets (or with nil clears) a node's region by hand. Only the template's region groups and
    /// edits that pick nodes by region read it, so the core reloads only when those exist.
    func markRegion(_ node: String, code: String?) {
        guard let id = activeProfileID else { return }
        var layer = routingStore.load(id)
        layer.regionMarks[node] = code
        regionMarks = layer.regionMarks
        if layer.template != nil || layer.edits.contains(where: \.enabled) {
            saveLayer(layer, for: id)
        } else {
            do { try routingStore.save(layer, for: id) } catch { notice = message(for: error) }
        }
    }

    /// The Mihomo inside the app bundle, or `VEER_MIHOMO_BIN` when running from the package.
    static var bundledCore: URL? {
        if let url = Bundle.main.url(forResource: "mihomo", withExtension: nil, subdirectory: "bin") { return url }
        return ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"].map { URL(fileURLWithPath: $0) }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "runtimeSettings") }
    }

    // MARK: Core

    func launch() {
        recoverStaleSystemProxy()
        watchNetwork()
        scheduleSubscriptionUpdates()
        for profile in profiles { alertAboutUsage(of: profile) }
        // After a stale update has gone, so that it isn't what starts.
        Task {
            await dropStaleCoreUpdate()
            if restoreLastState, state.running, activeProfile != nil { start() }
        }
    }

    /// When Veer last quit without cleaning up, the system proxy still points at its port with
    /// nothing listening, and every app loses the network. Put back what was there before; a port
    /// another app listens on is that app's and stays.
    private func recoverStaleSystemProxy() {
        let port = state.proxyPort ?? settings.mixedPort
        guard !Ports.inUse(port) else { return }
        if let snapshot = state.snapshot {
            try? systemProxy.restore(snapshot, host: "127.0.0.1", port: port)
            state.snapshot = nil
        } else if (try? systemProxy.isEnabled(host: "127.0.0.1", port: port)) == true {
            try? systemProxy.disable(host: "127.0.0.1", port: port)
        }
    }

    /// A network that appears later (a USB adapter, a new Wi-Fi service) gets the proxy too, and
    /// waking from sleep checks again.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in Task { @MainActor in self.coverNewServices() } }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.coverNewServices() }
        }
        // Coming back from System Settings, with the helper TUN was waiting for allowed.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if self.settings.tun, !self.tunActive { await self.refreshHelperState() }
            }
        }
    }

    private func coverNewServices() {
        guard systemProxyOn, var snapshot = state.snapshot, let services = try? systemProxy.services() else { return }
        let known = Set(snapshot.services.map(\.name))
        let added = services.filter { !known.contains($0) }
        guard !added.isEmpty, let recorded = try? systemProxy.snapshot(services: added) else { return }
        snapshot.merge(recorded)
        state.snapshot = snapshot
        try? systemProxy.enable(host: "127.0.0.1", port: proxyPort, services: added)
    }

    /// Validate before helper/TUN setup; the editor may still open damaged groups for repair.
    func startableText(of id: UUID) async throws -> String {
        let text = try await effectiveTextInBackground(of: id)
        try await Task.detached { try ConfigDocument.requireGroupMembers(in: text) }.value
        return text
    }

    func start() {
        guard phase != .starting, phase != .running else { return }
        notice = nil
        guard let profile = activeProfile else { return }
        guard let binary = activeBinary else {
            phase = .failed(String(localized: "应用包里缺少 Mihomo 内核，请重新安装 Veer。"), log: [])
            return
        }
        guard !Ports.inUse(settings.mixedPort) else {
            phase = .failed(Self.portInUseMessage(settings.mixedPort), log: [])
            return
        }
        phase = .starting
        let signpost = beginStartup()
        let ticket = generation
        coreConfigWork.add { [self] in
            defer {
                endStartup(signpost)
                if ticket == generation, let selected = profileAfterStartup {
                    profileAfterStartup = nil
                    activate(selected)
                }
            }
            guard phase == .starting, ticket == generation else { return }
            do {
                try await bringUpCore(profile: profile.id, binary: binary, ticket: ticket)
            } catch {
                guard ticket == generation, phase == .starting else { return }
                core?.stop()
                tunActive = false
                phase = .failed(message(for: error), log: core?.tail ?? [])
            }
        }
    }

    /// From the profile's text to a core that answers and carries traffic.
    private func bringUpCore(profile: UUID, binary: URL, ticket: Int) async throws {
        try paths.prepare()
        guard let port = pickControllerPort() else { throw EditorError(String(localized: "找不到可用的本机端口来控制内核。")) }
        let secret = RuntimeConfig.makeSecret()
        let text = try await startableText(of: profile)
        guard ticket == generation, phase == .starting else { return }
        reached(.configReady)
        let (core, tunFailure) = try await launchPreferringTUN(text: text, port: port, secret: secret, binary: binary)
        guard ticket == generation, phase == .starting else {
            core.stop()
            self.core = nil
            hotSets = nil
            tunActive = false
            return
        }
        let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
        self.controller = controller
        controllerAccess = (port, secret)
        runningPort = settings.mixedPort
        switch try await coreBecomesReady(controller, controllerPort: port, proxyPort: settings.mixedPort, log: { core.tail }) {
        case .calledOff: return
        case .ready: break
        case .timedOut:
            abandonStart(core)
            phase = .failed(String(localized: "内核在 60 秒内没有就绪，可能正在下载 GeoIP 数据或网络不通。"), log: core.tail)
            return
        case .portTaken(let conflict):
            abandonStart(core)
            logStartup("Port taken: \(conflict)")
            phase = .failed(Self.message(for: conflict), log: core.tail)
            return
        }
        guard ticket == generation, phase == .starting else { return }
        await coreDidStart(tunFailure: tunFailure)
        reached(.uiReady)
        logStartup("Core started")
    }

    /// Stops a core that never became ready and clears what its start set up, so the next start
    /// begins from nothing.
    private func abandonStart(_ core: CoreRunning) {
        core.stop()
        self.core = nil
        controller = nil
        controllerAccess = nil
        runningPort = nil
        hotSets = nil
        hotLines = [:]
        tunActive = false
    }

    /// Starts the core with TUN when it is on and the helper is ready; without it the core runs
    /// as the user and the system proxy carries the traffic instead. Returns why TUN did not run.
    private func launchPreferringTUN(text: String, port: Int, secret: String, binary: URL) async throws -> (CoreRunning, String?) {
        var tunFailure: String?
        if settings.tun {
            tunFailure = await tunProblem()
            reached(.helperChecked)
        }
        let launch = { (tun: Bool) in try await self.launchCore(tun: tun, text: text, port: port, secret: secret, binary: binary) }
        let useTUN = settings.tun && tunFailure == nil
        let core: CoreRunning, hot: HotRuleSets?
        do {
            (core, hot) = try await launch(useTUN)
        } catch where useTUN {
            tunFailure = message(for: error)
            (core, hot) = try await launch(false)
        }
        self.core = core
        hotSets = hot
        hotLines = [:]
        tunActive = useTUN && tunFailure == nil
        return (core, tunFailure)
    }

    /// Writes the runtime config, with its hot rule sets, and starts the core as root (TUN) or as
    /// the user.
    private func launchCore(tun: Bool, text: String, port: Int, secret: String, binary: URL) async throws -> (CoreRunning, HotRuleSets?) {
        var built = settings
        built.tun = tun
        let path = paths.runtimeConfig, home = paths.core
        let hot = await HotRuleSets.prepared(for: text, writer: hotWriter(tun: tun))
        try await Task.detached(priority: .userInitiated) { [built] in
            let yaml = try RuntimeConfig.build(profile: text, settings: built, controllerPort: port, secret: secret, hot: hot)
            try Data(yaml.utf8).write(to: path, options: .atomic)
        }.value
        let core: CoreRunning = tun ? HelperCore(geodata: home) : CoreProcess(binary: binary, home: home)
        reached(.runtimeWritten)
        try await core.start(config: path) { [weak self, weak core] status, log in
            Task { @MainActor in
                guard let self, let core, self.core === core else { return }
                self.coreExited(status: status, log: log)
            }
        }
        reached(.processStarted)
        return (core, hot)
    }

    /// The core answers: what runs alongside it starts, and the last mode and system proxy return.
    private func coreDidStart(tunFailure: String?) async {
        phase = .running
        state.running = true
        locateServersByIP()
        await refresh()
        // The mode and system proxy the user last chose come back with the core.
        if let saved = state.mode.flatMap(Mode.init(rawValue:)), saved != mode { setMode(saved) }
        startTraffic()
        startLogs()
        trackConnections()
        recheckExit()
        testEverythingOnce()
        if let tunFailure {
            // After the switch, which clears notices.
            if !systemProxyOn { fallBackToSystemProxy() }
            notice = String(localized: "TUN 未能启动，已改用系统代理。\(tunFailure)")
        } else if systemProxyIsFallback || (state.systemProxy && !systemProxyOn) {
            settleSystemProxy()
        }
    }

    /// Standing in for TUN, which is what was asked for, so not remembered as a choice of its own.
    private func fallBackToSystemProxy() {
        systemProxyIsFallback = !state.systemProxy
        setSystemProxy(true, remember: false)
    }

    /// Once the core runs without trouble: what stood in for TUN goes, what was chosen comes back.
    private func settleSystemProxy() {
        if systemProxyIsFallback {
            setSystemProxy(false, remember: false)
            systemProxyIsFallback = false
        } else {
            setSystemProxy(true)
        }
    }

    /// Why TUN cannot run now, or nil when the helper is ready.
    private func tunProblem() async -> String? {
        let state = await helperProbe()
        helperState = state
        switch state {
        case .ready: return nil
        case .notInstalled: return String(localized: "TUN 需要的后台服务还没有安装，可以在设置的 TUN 页安装。")
        case .needsApproval: return String(localized: "需要在系统设置的“登录项”中允许 Veer 的后台服务。")
        case .outdated: return String(localized: "后台服务的版本较旧，请在设置的 TUN 页重新安装。")
        case .unavailable(let reason): return reason
        }
    }

    /// Stops the core and starts it again with the current settings. The system proxy stays as
    /// it is: the port does not change, so it points at the new core once it runs.
    func restart() {
        guard isRunning else { return }
        tearDownCore()
        phase = .stopped
        start()
    }

    /// The TUN switch. Turning it on the first time registers the helper, which makes macOS ask
    /// for approval in System Settings; a running core then restarts (falling back to the system
    /// proxy until the helper is allowed).
    func setTUN(_ on: Bool) {
        notice = nil
        Task {
            if on, let consent = await HelperClient.shared.state().tunConsent {
                // Nothing is registered, and TUN stays off, until the person agrees.
                guard HelperPrompt.ask(consent) else { return await refreshHelperState() }
                do {
                    if consent == .install { try HelperClient.shared.register() }
                    if await HelperClient.shared.state() == .needsApproval { HelperClient.shared.openApprovalSettings() }
                } catch {
                    notice = message(for: error)
                }
            }
            settings.tun = on
            await refreshHelperState()
        }
    }

    func refreshHelperState() async {
        let previous = helperState
        let current = await helperProbe()
        helperState = current
        if current.finishesTUNSetup(from: previous, tunEnabled: settings.tun, tunActive: tunActive, running: isRunning) {
            notice = nil
            restart()
        }
    }

    /// Settings' TUN page: register with SMAppService, install by hand, or remove the helper.
    func registerHelper() {
        runHelperAction {
            try HelperClient.shared.register()
            if await HelperClient.shared.state() == .needsApproval { HelperClient.shared.openApprovalSettings() }
        }
    }

    /// An outdated or broken helper: installed again the way it was installed.
    func reinstallHelper() {
        if HelperClient.shared.isInstalledManually { return installHelperManually() }
        runHelperAction {
            try await HelperClient.shared.unregister()
            // launchd takes a moment to remove the old job; registering before that fails.
            for attempt in 1...10 {
                do {
                    try HelperClient.shared.register()
                    break
                } catch where attempt < 10 {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            if await HelperClient.shared.state() == .needsApproval { HelperClient.shared.openApprovalSettings() }
        }
    }

    func installHelperManually() {
        runHelperAction { try await HelperClient.shared.installManually() }
    }

    func uninstallHelper() {
        // The core must not keep running from the helper that is going away.
        if settings.tun { settings.tun = false }
        runHelperAction {
            if HelperClient.shared.isInstalledManually { try await HelperClient.shared.uninstallManually() }
            try await HelperClient.shared.unregister()
        }
    }

    private func runHelperAction(_ action: @escaping () async throws -> Void) {
        guard !helperBusy else { return }
        helperBusy = true
        notice = nil
        Task {
            defer { helperBusy = false }
            do { try await action() } catch { notice = message(for: error) }
            await refreshHelperState()
        }
    }

    /// Whether the system proxy comes on with the core.
    var systemProxyRemembered: Bool {
        get { state.systemProxy }
        set { state.systemProxy = newValue }
    }

    /// Starts the core and turns the system proxy on once it runs, as onboarding's one switch does.
    func startWithSystemProxy() {
        state.systemProxy = true
        start()
    }

    /// The user stopping the core; the next launch stays stopped. The system proxy goes off with it
    /// and comes back with the next start: stopping says nothing about wanting it off.
    func stop() {
        state.running = false
        systemProxyIsFallback = false
        if systemProxyOn { setSystemProxy(false, remember: false) }
        tearDownCore()
        phase = .stopped
    }

    /// Stops the core and everything watching it; the system proxy and saved state stay.
    private func tearDownCore() {
        resetDelays()
        switchingTo = nil
        profileAfterStartup = nil
        committedProfileID = nil
        trafficTask?.cancel()
        logTask?.cancel()
        connectionsTask?.cancel()
        connections = []
        loggedRoutes = []
        hotSets = nil
        hotLines = [:]
        core?.stop()
        core = nil
        tunActive = false
        controller = nil
        controllerAccess = nil
        runningPort = nil
        groups = []
        uploadRate = 0
        downloadRate = 0
        lastTotals = nil
    }

    /// Before the app quits: the system proxy must not point at a core that is gone.
    func shutdown() {
        if systemProxyOn { restoreSystemProxy() }
        core?.stop()
    }

    private func coreExited(status: Int32, log: [String]) {
        guard core != nil else { return }
        resetDelays()
        switchingTo = nil
        committedProfileID = nil
        if systemProxyOn { restoreSystemProxy() }
        trafficTask?.cancel()
        logTask?.cancel()
        connectionsTask?.cancel()
        connections = []
        hotSets = nil
        hotLines = [:]
        core = nil
        tunActive = false
        controller = nil
        controllerAccess = nil
        runningPort = nil
        groups = []
        uploadRate = 0
        downloadRate = 0
        let reason = log.last { $0.contains("level=fatal") || $0.contains("level=error") }.map(Self.logMessage)
        phase = .failed(reason.map { String(localized: "内核退出了：\($0)") } ?? String(localized: "内核意外退出（状态 \(Int(status))）。"), log: log)
    }

    /// The `msg=` part of a Mihomo log line, or the line itself.
    static func logMessage(_ line: String) -> String {
        guard let range = line.range(of: "msg=") else { return line }
        return String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    // MARK: Running core

    func refresh() async {
        guard let controller else { return }
        let ticket = generation
        do {
            let proxies = try await controller.proxies()
            guard ticket == generation else { return }
            // GLOBAL lists every policy in config order; the dictionary has none.
            let order = proxies["GLOBAL"]?.all ?? proxies.keys.sorted()
            groups = order.compactMap { proxies[$0] }.filter { $0.isGroup && $0.hidden != true }.map { group in
                Group(name: group.name, type: group.type, now: group.now, members: (group.all ?? []).map { name in
                    // A policy that blocks can't answer a delay test, and isn't timing out.
                    let blocks = Self.untestable.contains(name)
                    return Group.Member(name: name, delay: blocks ? nil : proxies[name]?.lastDelay,
                                        isGroup: proxies[name]?.isGroup == true, state: blocks ? .untested : delays[name])
                })
            }
            syncDelayCells()
            warmNodeLookups(Set(groups.flatMap { $0.members.map(\.name) }))
            let mode = Mode(rawValue: try await controller.mode().lowercased())
            if ticket == generation, let mode { self.mode = mode }
        } catch {
            if ticket == generation { notice = message(for: error) }
        }
    }

    /// The user picking a node: the same path as the Agent's (`choose`), so both are one runtime
    /// call with no reload, confirmed by reading the group back.
    func select(_ member: String, in group: String) {
        guard isRunning else { return }
        Task {
            do { try await choose(member, in: group) } catch {
                notice = message(for: error)
                await refresh()
            }
        }
    }

    func setMode(_ mode: Mode) {
        guard let controller else { self.mode = mode; return }
        Task {
            do {
                try await controller.setMode(mode.rawValue)
                self.mode = mode
                state.mode = mode.rawValue
                checkExit(after: .milliseconds(500))
            } catch { notice = message(for: error) }
        }
    }

    /// The user turning the system proxy on or off; remembered for the next start unless `remember` is false.
    /// `networksetup` runs once per service and setting, which takes long enough to stall the
    /// switch; it runs in the background while the switch already shows the new state. One change at
    /// a time and none dropped: a stop during a turn-on that skipped its restore would leave the Mac's
    /// proxy pointing at a core that has gone.
    func setSystemProxy(_ on: Bool, remember: Bool = true) {
        notice = nil
        guard !on || isRunning else { return }
        systemProxyOn = on
        if remember {
            state.systemProxy = on
            systemProxyIsFallback = false
        }
        let proxy = systemProxy, port = proxyPort
        systemProxyWork.add { [self] in
            // Read now: the change before this one may have just recorded it.
            let snapshot = state.snapshot
            do {
                if on {
                    // Record what each service had first, so turning off puts it back.
                    let recorded = try await Task.detached { () -> ProxySnapshot in
                        let recorded = try snapshot ?? proxy.snapshot()
                        try proxy.enable(host: "127.0.0.1", port: port)
                        return recorded
                    }.value
                    state.snapshot = recorded
                    state.proxyPort = port
                } else {
                    try await Task.detached {
                        if let snapshot { try proxy.restore(snapshot, host: "127.0.0.1", port: port) } else { try proxy.disable(host: "127.0.0.1", port: port) }
                    }.value
                    state.snapshot = nil
                }
            } catch {
                systemProxyOn = !on
                if remember { state.systemProxy = !on }
                notice = message(for: error)
            }
        }
    }

    /// Puts each service's own proxy settings back, without changing what the next launch does.
    private func restoreSystemProxy() {
        do {
            if let snapshot = state.snapshot {
                try systemProxy.restore(snapshot, host: "127.0.0.1", port: proxyPort)
            } else {
                try systemProxy.disable(host: "127.0.0.1", port: proxyPort)
            }
            state.snapshot = nil
            systemProxyOn = false
        } catch {
            notice = message(for: error)
        }
    }

    private func startTraffic() {
        trafficTask?.cancel()
        lastTotals = nil
        runningSince = .now
        uploadTotal = 0
        downloadTotal = 0
        uploadPeak = 0
        downloadPeak = 0
        trafficTask = Task {
            while !Task.isCancelled, let controller {
                if let totals = try? await controller.trafficSnapshot() {
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

    // MARK: Dashboard

    /// Public sites the dashboard checks through the proxy, with their latency in ms (nil while
    /// checking, 0 when unreachable).
    static let services: [(name: String, symbol: String, url: String)] = [
        ("Google", "magnifyingglass", "https://www.google.com/generate_204"),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/"),
        ("YouTube", "play.rectangle", "https://www.youtube.com/"),
        ("ChatGPT", "sparkles", "https://chatgpt.com/"),
    ]

    /// Times one request to each service through Veer's port.
    func checkServices() {
        guard isRunning else { serviceDelays = [:]; return }
        let port = proxyPort
        serviceDelays = [:]
        Task {
            await withTaskGroup(of: (String, Int).self) { group in
                for service in Self.services {
                    group.addTask { (service.name, await Self.latency(of: service.url, port: port)) }
                }
                for await (name, delay) in group { serviceDelays[name] = delay }
            }
        }
    }

    nonisolated static func latency(of url: String, port: Int) async -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: "127.0.0.1", kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: "127.0.0.1", kCFNetworkProxiesHTTPSPort: port,
        ] as [AnyHashable: Any]
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: url) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let start = Date()
        guard (try? await session.data(for: request)) != nil else { return 0 }
        return max(1, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// This Mac's address on the local network (the first active IPv4 interface).
    nonisolated static var localAddress: String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    /// Loads the active profile into the running core without restarting it. Open connections keep
    /// the route they opened with; those `reconnect` names as moved by the change are closed so they
    /// take the new one, and nothing else (`ReconnectPolicy`).
    func reloadRunningCore(reconnect: ReconnectPolicy.Change = .unknown) async {
        await coreConfigWork.add { [self] in
            guard let id = activeProfileID, switchingTo == nil else { return }
            do {
                _ = try await reloadRunningCoreNow(profile: id, reconnect: reconnect)
            } catch {
                if activeProfileID == id, switchingTo == nil { notice = message(for: error) }
            }
        }.value
    }

    /// Runs inside `coreConfigWork`. False if the requested profile was skipped or the core stopped.
    func reloadRunningCoreNow(profile id: UUID, reconnect: ReconnectPolicy.Change = .unknown) async throws -> Bool {
        guard isRunning, activeProfileID == id, let controller, let access = controllerAccess else { return false }
        let ticket = generation
        let timeline = ChangeTimeline(kind: "reload")
        defer { timeline.finish() }
        var running = settings
        running.mixedPort = proxyPort
        running.tun = tunActive
        let text = try await effectiveTextInBackground(of: id)
        guard controllerAccess?.secret == access.secret else { return false }
        let writer = hotWriter(tun: tunActive)
        // The config now holds every route, so the hot rule sets start over empty.
        let hot = await HotRuleSets.prepared(for: text, writer: writer)
        timeline.mark("effective")
        let built = running
        let yaml: String
        do {
            yaml = try await Task.detached(priority: .userInitiated) {
                try RuntimeConfig.build(profile: text, settings: built, controllerPort: access.port, secret: access.secret, hot: hot)
            }.value
            guard controllerAccess?.secret == access.secret else { return false }
            timeline.mark("yaml")
            try await controller.apply(yaml, mode: .config)
        } catch {
            await restoreHotFiles(using: writer)
            throw error
        }
        timeline.mark("putConfigs")
        // The accepted config is the only one persisted as the runtime copy. If a switch is queued
        // it will replace this copy next, and can roll back using the previous profile's source.
        guard controllerAccess?.secret == access.secret else { return false }
        hotSets = hot
        hotLines = [:]
        let path = paths.runtimeConfig
        try await Task.detached(priority: .userInitiated) { try Data(yaml.utf8).write(to: path, options: .atomic) }.value
        guard ticket == generation else { return true }
        await self.reconnect(after: reconnect)
        timeline.mark("reconnect")
        if ticket == generation, switchingTo == nil { await refresh() }
        return controllerAccess?.secret == access.secret
    }

    // MARK: Connections and logs

    /// The connections page shows live rows only while it is open.
    func watchConnections(_ on: Bool) {
        connectionsVisible = on
    }

    /// Polls `/connections` every second while the core runs: closed connections become
    /// requests, and the connections page gets its rows while it is open.
    private func trackConnections() {
        connectionsTask?.cancel()
        previousConnections = [:]
        connectionsTask = Task {
            while !Task.isCancelled {
                if let controller, let list = try? await controller.connections() {
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

    /// Connections in the last poll but not in this one have closed. New ones that fell through
    /// to MATCH count toward a suggestion.
    private func recordClosed(now rows: [ConnectionRow], at time: Date = .now) {
        let current = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows where previousConnections[row.id] == nil && row.rule.hasPrefix("Match") && !row.isAddress {
            suggest(detector.matchedFinalRule(host: row.host, at: time))
        }
        withdrawResolvedSuggestions(at: time)
        let closed = previousConnections.values.filter { current[$0.id] == nil }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            .map { ClosedRequest(row: $0, closedAt: time) }
        previousConnections = current
        for row in rows { polledKeys[row.matchKey] = time }
        polledKeys = polledKeys.filter { time.timeIntervalSince($0.value) < 30 }
        let short = settleLoggedRoutes(at: time)
        guard !closed.isEmpty || !short.isEmpty else { return }
        requests.insert(contentsOf: closed + short, at: 0)
        if !short.isEmpty { requests.sort { $0.closedAt > $1.closedAt } }
        if requests.count > Self.requestLimit { requests.removeLast(requests.count - Self.requestLimit) }
    }

    /// Logged routes two seconds old: a poll that saw the same host and app since has them (and
    /// records them with their traffic when they close); the rest were over too fast to see.
    private func settleLoggedRoutes(at time: Date) -> [ClosedRequest] {
        var short: [ClosedRequest] = []
        loggedRoutes.removeAll { route in
            guard time.timeIntervalSince(route.at) >= 2 else { return false }
            if let seen = polledKeys[route.row.matchKey], seen >= route.at.addingTimeInterval(-1) { return true }
            short.append(ClosedRequest(row: route.row, closedAt: route.at, fromLog: true))
            return true
        }
        return short
    }

    func clearRequests() { requests = [] }

    /// What Undo brings back, behind anything that has ended since, up to the usual limit.
    func restoreRequests(_ saved: [ClosedRequest]) { requests = Array((requests + saved).prefix(Self.requestLimit)) }

    // MARK: Suggestions

    /// At most `suggestionLimit`: the most serious first, and among equals the newest; the last makes
    /// room. An outage replaces the suggestions about each of its hosts, and its own earlier form.
    private func suggest(_ suggestion: Suggestion?) {
        guard let suggestion else { return }
        var list = suggestions.filter { $0.id != suggestion.id }
        if case .outage(_, let hosts) = suggestion.kind {
            list.removeAll { if case .failing(let host, _) = $0.kind { hosts.contains(host) } else { false } }
        } else if suggestions.contains(where: { $0.id == suggestion.id }) {
            return
        }
        list.insert(suggestion, at: 0)
        suggestions = Array(Self.ordered(list).prefix(Self.suggestionLimit))
    }

    /// Most serious first; a stable sort, so the newest stays ahead among equals.
    nonisolated static func ordered(_ list: [Suggestion]) -> [Suggestion] {
        list.enumerated().sorted { ($0.element.severity, -$0.offset) > ($1.element.severity, -$1.offset) }.map(\.element)
    }

    /// Withdraws suggestions whose cause has stopped.
    private func withdrawResolvedSuggestions(at time: Date) {
        let gone = detector.resolved(at: time)
        if !gone.isEmpty { suggestions.removeAll { gone.contains($0.id) } }
    }

    static let suggestionLimit = 5

    /// After a delay test: a select group whose node timed out twice in a row.
    func checkTestedNodes() {
        for group in groups where group.isSelectable {
            guard let now = group.now, let member = group.members.first(where: { $0.name == now }), !member.isGroup else { continue }
            suggest(detector.tested(node: now, in: group.name, delay: delays[now]?.legacyDelay ?? member.delay))
        }
    }

    /// Closes a suggestion; `forever` stops suggestions about its host.
    func dismiss(_ suggestion: Suggestion, forever: Bool = false) {
        suggestions.removeAll { $0.id == suggestion.id }
        detector.dismiss(suggestion)
        if forever, let host = suggestion.host {
            detector.ignoredHosts.insert(host)
            defaults.set(Array(detector.ignoredHosts), forKey: "ignoredSuggestionHosts")
        }
    }

    /// Asks the core's DNS, for the DNS page.
    func lookUp(_ name: String, type: String) async throws -> MihomoController.DNSResult {
        guard let controller else { throw EditorError(String(localized: "内核没有运行。")) }
        return try await controller.dnsQuery(name, type: type)
    }

    /// Closes the open connections `change` moves to another route, so they take it now; the rest,
    /// and those `ReconnectPolicy` keeps (remote shells, coding agents, large transfers), stay.
    /// Returns how many were closed.
    @discardableResult func reconnect(after change: ReconnectPolicy.Change) async -> Int {
        let ticket = generation
        guard reconnectAfterChanges, change != .unknown, let controller, let list = try? await controller.connections() else { return 0 }
        let plan = ReconnectPolicy.plan(change, connections: list)
        var closed = 0
        for id in plan.close {
            guard ticket == generation else { return closed }
            if (try? await controller.closeConnection(id)) != nil { closed += 1 }
        }
        if plan.kept > 0 { logStartup("Reconnect: \(closed) closed, \(plan.kept) kept on their old route") }
        return closed
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
        guard let controller else { return }
        let level = settings.logLevel
        logTask = Task {
            do {
                for try await line in controller.logs(level: level) {
                    if let host = SuggestionDetector.failedHost(inLog: line.payload) {
                        suggest(detector.connectionFailed(host: host, exit: SuggestionDetector.failedExit(inLog: line.payload)))
                    }
                    if let route = LogRoute.parse(line.payload) {
                        loggedRoutes.append((ConnectionRow(route: route, at: .now), .now))
                        if loggedRoutes.count > 2000 { loggedRoutes.removeFirst(loggedRoutes.count - 2000) }
                    }
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

    /// Group and node names a manual rule can send traffic to: groups first, then built-ins.
    /// Parsed off the main thread; call once, not while drawing.
    func ruleTargets() async -> [String] {
        guard let id = activeProfileID, let text = try? await effectiveTextInBackground(of: id) else { return [] }
        let groups = await Task.detached { (try? ConfigDocument.parse(text))?.targets.filter { $0.kind == .group }.map(\.name) ?? [] }.value
        return groups + ["DIRECT", "REJECT"]
    }

    /// Adds `matchType,value,target` to the active profile's "my routing", at the top of the rules.
    /// The config is parsed off the main thread; the core reloads and reconnects at once.
    func addRule(matchType: String, value: String, target: String) async throws {
        guard let id = activeProfileID else { return }
        let text = try await effectiveTextInBackground(of: id)
        let prompt = String(localized: "\(value) 走 \(target)"), missing = String(localized: "找不到出口“\(target)”。")
        let edit = try await Task.detached(priority: .userInitiated) { () -> RoutingLayer.Edit in
            let document = try ConfigDocument.parse(text)
            guard let exit = document.target(named: target) else { throw EditorError(missing) }
            let plan = EditPlan(operations: [.route(matchType: matchType, match: value, targetId: exit.id)])
            let result = try PlanApplier.apply(plan, to: document)
            return RoutingLayer.Edit(source: .manual, prompt: prompt, plan: plan, accepted: Set(result.items.map(\.id)),
                                     items: result.items, base: text)
        }.value
        addEdit(edit, to: id)
    }

    /// What the health check finds in a profile as it runs (with "my routing" applied).
    func healthFindings(of id: UUID) async -> [HealthFinding] {
        guard let text = try? await effectiveTextInBackground(of: id) else { return [] }
        return await Task.detached { ConfigHealthCheck.run(text).sorted { $0.severity < $1.severity } }.value
    }

    /// Records a finding's safe fix in "my routing", so it holds after the subscription updates.
    func applyFix(_ finding: HealthFinding, in id: UUID) async throws {
        let text = try await effectiveTextInBackground(of: id)
        let edit = try await Task.detached(priority: .userInitiated) { () -> RoutingLayer.Edit in
            let plan = EditPlan(operations: finding.fix)
            let result = try PlanApplier.apply(plan, to: try ConfigDocument.parse(text))
            return RoutingLayer.Edit(source: .healthCheck, prompt: finding.fixTitle ?? finding.title, plan: plan,
                                     accepted: Set(result.items.map(\.id)), items: result.items, base: text)
        }.value
        addEdit(edit, to: id)
    }

    // MARK: Agent actions on the running core

    func runningController() throws -> MihomoController {
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

    /// The group as last read, or as the core reports it when Veer has not read it.
    func knownGroup(_ name: String) async throws -> Group {
        if let group = groups.first(where: { $0.name == name }) { return group }
        return try await liveGroup(name)
    }

    /// Selects `node` in a select group with one runtime call (`PUT /proxies/{group}`), no reload,
    /// and reads the group back to confirm the core took it; returns the node it replaced. The
    /// manual switch, the menu bar and the Agent all come through here.
    @discardableResult func choose(_ node: String, in name: String) async throws -> String? {
        let controller = try runningController()
        let started = generation
        let group = try await knownGroup(name)
        guard switchingTo == nil, started == generation else { throw EditorError(String(localized: "配置已经切换，没有改动节点。")) }
        guard group.isSelectable else { throw EditorError(String(localized: "“\(name)”按延迟自动选择，不能手动切换节点。")) }
        let previous = group.now
        try await controller.select(node, in: name)
        guard started == generation else { throw EditorError(String(localized: "配置已经切换，没有改动节点。")) }
        let now = try await controller.selection(of: name)
        guard started == generation else { throw EditorError(String(localized: "配置已经切换，没有改动节点。")) }
        guard now == node else {
            throw EditorError(String(localized: "内核没有切换到 \(node)，“\(name)”仍在使用 \(now ?? "—")。"))
        }
        groups = groups.map { $0.name == name ? Group(name: $0.name, type: $0.type, now: node, members: $0.members) : $0 }
        await reconnect(after: .selection(group: name))
        if started == generation { checkExit(after: .milliseconds(500)) }
        return previous
    }

    /// Switches the mode; returns the one it replaced.
    @discardableResult func switchMode(_ mode: Mode) async throws -> Mode {
        let controller = try runningController()
        let previous = self.mode
        try await controller.setMode(mode.rawValue)
        self.mode = mode
        state.mode = mode.rawValue
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
        let result = try effectiveStore.effective(of: id, profiles: profileStore, routing: routingStore)
        remember(result, for: id)
        return result.text
    }

    /// The same, built off the main thread: parsing and replaying a large subscription takes long
    /// enough to stall the window.
    func effectiveTextInBackground(of id: UUID) async throws -> String {
        let routingStore = routingStore, profileStore = profileStore, effectiveStore = effectiveStore
        while true {
            if let cached = effectiveCache[id] { return cached.text }
            let revision = effectiveRevisions[id, default: 0]
            let result = try await Task.detached(priority: .userInitiated) {
                try effectiveStore.effective(of: id, profiles: profileStore, routing: routingStore)
            }.value
            if effectiveRevisions[id, default: 0] == revision {
                remember(result, for: id)
                return result.text
            }
        }
    }

    func remember(_ result: EffectiveConfig, for id: UUID) {
        effectiveCache[id] = result
        if id == activeProfileID { effective = result }
    }

    /// The profile's text or layer changed: its effective config has to be built again.
    func forgetEffective(_ id: UUID) {
        effectiveRevisions[id, default: 0] += 1
        effectiveCache[id] = nil
        if id == activeProfileID { effective = nil }
    }

    func layer(of id: UUID) -> RoutingLayer { routingStore.load(id) }

    /// Node names of the profile as downloaded, in order.
    func nodeNames(of id: UUID) -> [String] {
        guard let text = try? profileStore.text(of: id), let document = try? ConfigDocument.parse(text) else { return [] }
        return document.targets.filter { $0.kind == .node }.map(\.name)
    }

    /// Checks or unchecks a node; the running core picks it up at once.
    func setNode(_ name: String, included: Bool, in id: UUID) {
        var layer = routingStore.load(id)
        if included { layer.excludedNodes.remove(name) } else { layer.excludedNodes.insert(name) }
        saveLayer(layer, for: id)
    }

    /// Adds an applied Agent change; false (with a notice) when it could not be saved.
    @discardableResult func addEdit(_ edit: RoutingLayer.Edit, to id: UUID) -> Bool {
        var layer = routingStore.load(id)
        layer.edits.append(edit)
        return saveLayer(layer, for: id, reconnect: Self.reconnectChange(for: edit), hotEdit: edit)
    }

    /// The open connections an edit's routes move: hosts and addresses its accepted route rules
    /// match. Rule sets, groups and removals can't be told apart this way, so they move none.
    static func reconnectChange(for edit: RoutingLayer.Edit) -> ReconnectPolicy.Change {
        let routes = edit.items.filter { edit.accepted.contains($0.id) && $0.kind == .route }
        let lines = routes.compactMap { item -> String? in
            ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6"].contains(item.matchType) ? "\(item.matchType),\(item.match)" : nil
        }
        guard !lines.isEmpty else { return .unknown }
        let targets = Set(routes.compactMap(\.targetName))
        return .rules(lines, target: targets.count == 1 ? targets.first : nil)
    }

    /// False when the change has gone or could not be saved.
    @discardableResult func setEdit(_ editID: UUID, enabled: Bool, in id: UUID) -> Bool {
        var layer = routingStore.load(id)
        guard let index = layer.edits.firstIndex(where: { $0.id == editID }) else { return false }
        layer.edits[index].enabled = enabled
        // Undone or redone, its routes move the same connections, back or forth.
        let reconnect = Self.reconnectChange(for: layer.edits[index])
        return saveLayer(layer, for: id, reconnect: reconnect.withoutTarget)
    }

    /// Uses a built-in rule template for a profile, or with nil goes back to its own rules.
    func setTemplate(_ template: String?, for id: UUID) {
        var layer = routingStore.load(id)
        guard layer.template != template else { return }
        layer.template = template
        saveLayer(layer, for: id)
    }

    func deleteEdit(_ editID: UUID, in id: UUID) {
        var layer = routingStore.load(id)
        layer.edits.removeAll { $0.id == editID }
        saveLayer(layer, for: id)
        editsRemoved?([editID])
    }

    @discardableResult private func saveLayer(_ layer: RoutingLayer, for id: UUID, reconnect: ReconnectPolicy.Change = .unknown,
                                              hotEdit: RoutingLayer.Edit? = nil) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        do {
            try routingStore.save(layer, for: id)
            forgetEffective(id)
            if id == activeProfileID || id == committedProfileID {
                layerApply = coreConfigWork.add { [self] in
                    guard isRunning, id == activeProfileID, switchingTo == nil else { return .saved }
                    do {
                        if let hotEdit, let entries = hotEntries(for: hotEdit),
                           routingStore.load(id).edits.contains(where: { $0.id == hotEdit.id && $0.enabled }) {
                            return try await applyHotNow(entries, profile: id) ? .running : .saved
                        }
                        return try await reloadRunningCoreNow(profile: id, reconnect: reconnect) ? .running : .saved
                    } catch {
                        let reason = message(for: error)
                        if id == activeProfileID, switchingTo == nil { notice = reason }
                        return .refused(reason)
                    }
                }
            }
            return true
        } catch {
            notice = message(for: error)
            return false
        }
    }

    /// The config as the core runs it, for saving elsewhere; with Veer's port and overrides when
    /// `withOverrides`, never with the controller or its secret.
    func exportText(of id: UUID, withOverrides: Bool) throws -> String {
        let text = try routingStore.load(id).apply(to: try profileStore.text(of: id)).text
        return withOverrides ? try RuntimeConfig.export(profile: text, settings: settings) : text
    }

    /// The files of a diagnostics bundle, built off the main thread.
    func diagnosticItems() async -> [Diagnostics.Item] {
        var config: String?
        if let id = activeProfileID { config = try? await effectiveTextInBackground(of: id) }
        let coreVersion = await CoreUpdater.version(of: reportedBinary ?? URL(fileURLWithPath: "/nonexistent"))
        let state = (try? Data(contentsOf: paths.state)).map { String(decoding: $0, as: UTF8.self) }
        let logs = logs.map { "\($0.time.formatted(.iso8601)) [\($0.level)] \($0.message)" }
        let settings = settings, tail = core?.tail ?? [], version = AboutSettings.version, startup = startup?.report
        return await Task.detached {
            Diagnostics.collect(appVersion: version, coreVersion: coreVersion, settings: settings, state: state,
                                effectiveConfig: config, logs: logs, coreTail: tail, startup: startup)
        }.value
    }

    /// Low traffic or a near expiry, as one system notification each (see `UsageAlertLedger`).
    func alertAboutUsage(of profile: Profile, now: Date = .now) {
        for alert in UsageAlertLedger(defaults: defaults).take(for: profile, now: now) {
            notifier(Self.alertText(alert, profile: profile, now: now))
        }
    }

    static func alertText(_ alert: UsageAlert, profile: Profile, now: Date) -> (title: String, body: String) {
        switch alert {
        case .traffic:
            let left = max((profile.usage?.total ?? 0) - (profile.usage?.used ?? 0), 0)
            return (String(localized: "“\(profile.name)”的流量快用完了"),
                    String(localized: "还剩 \(Format.bytes(left))，已不到总量的十分之一。"))
        case .expiry:
            let expire = profile.usage?.expire ?? now
            return expire <= now
                ? (String(localized: "“\(profile.name)”已经到期"), String(localized: "续费后更新这份配置即可继续使用。"))
                : (String(localized: "“\(profile.name)”即将到期"),
                   String(localized: "到期时间：\(expire.formatted(date: .abbreviated, time: .shortened))。"))
        }
    }

    func message(for error: Error) -> String {
        (error as? EditorError)?.message ?? error.localizedDescription
    }
}
