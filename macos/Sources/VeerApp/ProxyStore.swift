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
    var phase: Phase = .stopped
    var profiles: [Profile] = []
    var activeProfileID: UUID? { didSet { defaults.set(activeProfileID?.uuidString, forKey: "activeProfile") } }
    var groups: [Group] = []
    var mode: Mode = .rule
    var systemProxyOn = false
    var uploadRate: Int64 = 0
    var downloadRate: Int64 = 0
    var testingGroups: Set<String> = []
    var updatingProfiles: Set<UUID> = []
    /// An action's failure, shown where the action is until the next one.
    var notice: String?

    /// Where first-run onboarding is; nil once it is done or when there were profiles already.
    var onboarding: OnboardingStep?

    var showingImport = false
    var importText = ""
    var importing = false
    var importError: String?

    var settings: RuntimeSettings {
        didSet {
            saveSettings()
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
                if settings.logLevel != oldValue.logLevel { startLogs() }
            }
        }
    }
    @ObservationIgnored private var settingsReload: Task<Void, Never>?
    /// Effective configs by profile, so views and the Agent do not rebuild them on every draw.
    @ObservationIgnored private var effectiveCache: [UUID: EffectiveConfig] = [:]
    /// Where traffic leaves the proxy: shown on the overview while the core runs.
    var exit: ExitInfo?
    var showExitIP: Bool { didSet { defaults.set(showExitIP, forKey: "showExitIP"); if !showExitIP { exit = nil } } }
    @ObservationIgnored private var exitCheck: Task<Void, Never>?
    /// Start the core, the system proxy and the mode as they were when Veer last quit.
    var restoreLastState: Bool { didSet { defaults.set(restoreLastState, forKey: "restoreLastState") } }
    var showRateInMenuBar: Bool { didSet { defaults.set(showRateInMenuBar, forKey: "showRateInMenuBar") } }
    /// Close open connections after a profile switch, a routing change or a node switch, so they
    /// reconnect the new way instead of staying on the old route.
    var reconnectAfterChanges: Bool { didSet { defaults.set(reconnectAfterChanges, forKey: "reconnectAfterChanges") } }
    @ObservationIgnored private var systemProxyBusy = false
    /// Groups folded on the Proxies page, by name; remembered across launches.
    var collapsedGroups: Set<String> { didSet { defaults.set(Array(collapsedGroups), forKey: "collapsedGroups") } }
    /// The active profile with its "my routing" layer applied, as the core last loaded it.
    var effective: EffectiveConfig?

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var isRunning: Bool { phase == .running }
    /// The select group people switch most: the first one in the config.
    var mainGroup: Group? { groups.first(where: \.isSelectable) }

    // MARK: Dependencies

    let paths: VeerPaths
    let profileStore: ProfileStore
    let routingStore: RoutingStore
    let stateStore: StateStore
    let systemProxy: SystemProxy
    let binary: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var core: CoreProcess?
    @ObservationIgnored private var controller: MihomoController?
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
        self.defaults = defaults
        settings = defaults.data(forKey: "runtimeSettings").flatMap { try? JSONDecoder().decode(RuntimeSettings.self, from: $0) } ?? RuntimeSettings()
        restoreLastState = defaults.object(forKey: "restoreLastState") as? Bool ?? true
        showRateInMenuBar = defaults.bool(forKey: "showRateInMenuBar")
        showExitIP = defaults.object(forKey: "showExitIP") as? Bool ?? true
        reconnectAfterChanges = defaults.object(forKey: "reconnectAfterChanges") as? Bool ?? true
        collapsedGroups = Set(defaults.stringArray(forKey: "collapsedGroups") ?? [])
        state = stateStore.load()
        profiles = profileStore.loadAll()
        activeProfileID = defaults.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:)).flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        if profiles.isEmpty { onboarding = .addProfile }
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
        if restoreLastState, state.running, activeProfile != nil { start() }
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

    func start() {
        guard phase != .starting, phase != .running else { return }
        notice = nil
        guard let profile = activeProfile else { return }
        guard let binary else {
            phase = .failed(String(localized: "应用包里缺少 Mihomo 内核，请重新安装 Veer。"), log: [])
            return
        }
        guard !Ports.inUse(settings.mixedPort) else {
            phase = .failed(String(localized: "端口 \(String(settings.mixedPort)) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。"), log: [])
            return
        }
        phase = .starting
        Task {
            do {
                try paths.prepare()
                guard let port = Ports.free() else { throw EditorError(String(localized: "找不到可用的本机端口来控制内核。")) }
                let secret = RuntimeConfig.makeSecret()
                let text = try await effectiveTextInBackground(of: profile.id)
                let path = paths.runtimeConfig, built = settings
                try await Task.detached(priority: .userInitiated) {
                    let yaml = try RuntimeConfig.build(profile: text, settings: built, controllerPort: port, secret: secret)
                    try Data(yaml.utf8).write(to: path, options: .atomic)
                }.value
                let core = CoreProcess(binary: binary, home: paths.core)
                try core.start(config: paths.runtimeConfig) { status, log in
                    Task { @MainActor in self.coreExited(status: status, log: log) }
                }
                self.core = core
                let controller = MihomoController(base: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
                self.controller = controller
                controllerAccess = (port, secret)
                runningPort = settings.mixedPort
                // The first start can download geodata before the controller answers.
                for _ in 0..<600 {
                    if phase != .starting { return }
                    if (try? await controller.version()) != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard phase == .starting else { return }
                guard (try? await controller.version()) != nil else {
                    core.stop()
                    self.core = nil
                    self.controller = nil
                    phase = .failed(String(localized: "内核在 60 秒内没有就绪，可能正在下载 GeoIP 数据或网络不通。"), log: core.tail)
                    return
                }
                phase = .running
                state.running = true
                await refresh()
                // The mode and system proxy the user last chose come back with the core.
                if let saved = state.mode.flatMap(Mode.init(rawValue:)), saved != mode { setMode(saved) }
                startTraffic()
                startLogs()
                checkExit()
                testEverythingOnce()
                if state.systemProxy { setSystemProxy(true) }
            } catch {
                core?.stop()
                phase = .failed(message(for: error), log: core?.tail ?? [])
            }
        }
    }

    /// Starts the core and turns the system proxy on once it runs, as onboarding's one switch does.
    func startWithSystemProxy() {
        state.systemProxy = true
        start()
    }

    /// The user stopping the core; the next launch stays stopped.
    func stop() {
        state.running = false
        if systemProxyOn { setSystemProxy(false) }
        trafficTask?.cancel()
        logTask?.cancel()
        connectionsTask?.cancel()
        core?.stop()
        core = nil
        controller = nil
        controllerAccess = nil
        runningPort = nil
        phase = .stopped
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
        if systemProxyOn { restoreSystemProxy() }
        trafficTask?.cancel()
        logTask?.cancel()
        connectionsTask?.cancel()
        core = nil
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
        do {
            let proxies = try await controller.proxies()
            // GLOBAL lists every policy in config order; the dictionary has none.
            let order = proxies["GLOBAL"]?.all ?? proxies.keys.sorted()
            groups = order.compactMap { proxies[$0] }.filter { $0.isGroup && $0.hidden != true }.map { group in
                Group(name: group.name, type: group.type, now: group.now, members: (group.all ?? []).map { name in
                    Group.Member(name: name, delay: proxies[name]?.lastDelay, isGroup: proxies[name]?.isGroup == true)
                })
            }
            if let mode = Mode(rawValue: try await controller.mode().lowercased()) { self.mode = mode }
        } catch {
            notice = message(for: error)
        }
    }

    func select(_ member: String, in group: String) {
        guard let controller else { return }
        Task {
            do {
                try await controller.select(member, in: group)
                await closeConnections(through: group)
            } catch { notice = message(for: error) }
            await refresh()
            checkExit(after: .milliseconds(500))
        }
    }

    func testDelay(_ group: String) {
        guard let controller, !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        Task {
            do { _ = try await controller.testDelay(group: group) } catch {
                notice = String(localized: "“\(group)”测速失败：\(message(for: error))")
            }
            testingGroups.remove(group)
            await refresh()
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

    /// The user turning the system proxy on or off; remembered for the next launch.
    /// `networksetup` runs once per service and setting, which takes long enough to stall the
    /// switch; it runs in the background while the switch already shows the new state.
    func setSystemProxy(_ on: Bool) {
        notice = nil
        guard !on || isRunning, !systemProxyBusy else { return }
        systemProxyBusy = true
        systemProxyOn = on
        state.systemProxy = on
        let proxy = systemProxy, port = proxyPort, snapshot = state.snapshot
        Task {
            defer { systemProxyBusy = false }
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
                state.systemProxy = !on
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

    /// Loads the active profile into the running core without restarting it.
    /// Loads the active profile into the running core without restarting it. With
    /// `closingConnections` (a new profile or new rules), open connections are closed: the core
    /// keeps routing them the old way until they reconnect.
    private func reloadRunningCore(closingConnections: Bool = false) async {
        guard isRunning, let controller, let access = controllerAccess, let profile = activeProfile else { return }
        do {
            var running = settings
            running.mixedPort = proxyPort
            let text = try await effectiveTextInBackground(of: profile.id)
            let path = paths.runtimeConfig, port = access.port, secret = access.secret, built = running
            let yaml = try await Task.detached(priority: .userInitiated) {
                let yaml = try RuntimeConfig.build(profile: text, settings: built, controllerPort: port, secret: secret)
                try Data(yaml.utf8).write(to: path, options: .atomic)
                return yaml
            }.value
            try await controller.apply(yaml, mode: .config)
            if closingConnections && reconnectAfterChanges { try? await controller.closeAllConnections() }
            await refresh()
        } catch {
            notice = message(for: error)
        }
    }

    func toggleCollapsed(_ group: String) {
        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
    }

    func setAllCollapsed(_ collapsed: Bool) {
        collapsedGroups = collapsed ? Set(groups.map(\.name)) : []
    }

    /// One delay test of every node after the core starts, so the Proxies page and "fastest"
    /// choices have numbers at once. GLOBAL lists every node and group.
    private func testEverythingOnce() {
        guard let controller else { return }
        testingGroups.insert("GLOBAL")
        Task {
            _ = try? await controller.testDelay(group: "GLOBAL")
            testingGroups.remove("GLOBAL")
            await refresh()
        }
    }

    // MARK: Exit IP

    /// Asks a public IP service, through Veer's own port, where traffic leaves; a second service
    /// answers when the first fails. Runs again after a node or mode switch.
    func checkExit(after delay: Duration = .zero) {
        exitCheck?.cancel()
        guard showExitIP, isRunning else { exit = nil; return }
        let port = proxyPort
        exitCheck = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            exit = await ExitInfo.lookUp(throughPort: port) ?? ExitInfo.unknown
        }
    }

    // MARK: Connections and logs

    /// Polls `/connections` every second while `on` (the connections page is open).
    func watchConnections(_ on: Bool) {
        connectionsTask?.cancel()
        guard on else { return }
        connectionsTask = Task {
            while !Task.isCancelled {
                if !connectionsPaused, let controller, let list = try? await controller.connections() {
                    var rows: [ConnectionRow] = []
                    var bytes: [String: (Int64, Int64)] = [:]
                    for connection in list {
                        let last = lastConnectionBytes[connection.id]
                        rows.append(ConnectionRow(connection, uploadRate: last.map { max(0, connection.upload - $0.upload) } ?? 0,
                                                  downloadRate: last.map { max(0, connection.download - $0.download) } ?? 0))
                        bytes[connection.id] = (connection.upload, connection.download)
                    }
                    lastConnectionBytes = bytes.mapValues { (upload: $0.0, download: $0.1) }
                    connections = rows.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
                } else if controller == nil {
                    connections = []
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// After a node switch: connections that went through `group` keep their old node until they
    /// reconnect, so they are closed.
    func closeConnections(through group: String) async {
        guard reconnectAfterChanges, let controller, let list = try? await controller.connections() else { return }
        for connection in list where connection.chains.contains(group) { try? await controller.closeConnection(connection.id) }
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
                    guard !logsPaused else { continue }
                    logs.append(LogEntry(level: line.type, message: line.payload))
                    if logs.count > Self.logLimit { logs.removeFirst(logs.count - Self.logLimit) }
                }
            } catch {}
        }
    }

    func clearLogs() { logs = [] }

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
        let result = try routingStore.load(id).apply(to: try profileStore.text(of: id))
        remember(result, for: id)
        return result.text
    }

    /// The same, built off the main thread: parsing and replaying a large subscription takes long
    /// enough to stall the window.
    func effectiveTextInBackground(of id: UUID) async throws -> String {
        if let cached = effectiveCache[id] { return cached.text }
        let routingStore = routingStore, profileStore = profileStore
        let result = try await Task.detached(priority: .userInitiated) {
            try routingStore.load(id).apply(to: try profileStore.text(of: id))
        }.value
        remember(result, for: id)
        return result.text
    }

    private func remember(_ result: EffectiveConfig, for id: UUID) {
        effectiveCache[id] = result
        if id == activeProfileID { effective = result }
    }

    /// The profile's text or layer changed: its effective config has to be built again.
    private func forgetEffective(_ id: UUID) {
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
        return saveLayer(layer, for: id)
    }

    func setEdit(_ editID: UUID, enabled: Bool, in id: UUID) {
        var layer = routingStore.load(id)
        guard let index = layer.edits.firstIndex(where: { $0.id == editID }) else { return }
        layer.edits[index].enabled = enabled
        saveLayer(layer, for: id)
    }

    func deleteEdit(_ editID: UUID, in id: UUID) {
        var layer = routingStore.load(id)
        layer.edits.removeAll { $0.id == editID }
        saveLayer(layer, for: id)
    }

    @discardableResult private func saveLayer(_ layer: RoutingLayer, for id: UUID) -> Bool {
        do {
            try routingStore.save(layer, for: id)
            forgetEffective(id)
            if id == activeProfileID {
                Task {
                    _ = try? await effectiveTextInBackground(of: id)
                    if isRunning { await reloadRunningCore(closingConnections: true) }
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

    // MARK: Profiles

    func activate(_ id: UUID) {
        guard id != activeProfileID else { return }
        activeProfileID = id
        effective = effectiveCache[id]
        if isRunning {
            Task {
                await reloadRunningCore(closingConnections: true)
                // New nodes: measure them, and the exit may have moved.
                testEverythingOnce()
                checkExit()
            }
        } else if case .failed = phase { start() }
    }

    func delete(_ id: UUID) {
        if id == activeProfileID {
            stop()
            activeProfileID = profiles.first { $0.id != id }?.id
        }
        profileStore.delete(id)
        routingStore.delete(id)
        forgetEffective(id)
        profiles = profileStore.loadAll()
        if profiles.isEmpty { onboarding = .addProfile }
    }

    func openImport(prefill: String = "") {
        importText = prefill
        importError = nil
        showingImport = true
    }

    /// A subscription link, or pasted config / share links.
    func importFromText() {
        let input = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !importing else { return }
        importing = true
        importError = nil
        Task {
            defer { importing = false }
            do {
                if SubscriptionFetcher.looksLikeLink(input) {
                    let url = try SubscriptionFetcher.validate(input)
                    let response = try await SubscriptionFetcher().fetch(url)
                    let result = try ConfigImporter.normalize(response.text)
                    let profile = Profile(name: response.title ?? url.host() ?? String(localized: "订阅"), isSubscription: true, nodeCount: result.nodeCount, usage: response.usage)
                    try profileStore.save(profile, text: result.text)
                    try profileStore.setSubscriptionURL(url, for: profile.id)
                    added(profile)
                } else {
                    let result = try ConfigImporter.normalize(input)
                    let profile = Profile(name: String(localized: "粘贴的配置"), isSubscription: false, nodeCount: result.nodeCount)
                    try profileStore.save(profile, text: result.text)
                    added(profile)
                }
                showingImport = false
            } catch {
                importError = message(for: error)
            }
        }
    }

    func importFile(_ url: URL) {
        importError = nil
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try ConfigImporter.normalize(text)
            let profile = Profile(name: url.deletingPathExtension().lastPathComponent, isSubscription: false, nodeCount: result.nodeCount)
            try profileStore.save(profile, text: result.text)
            added(profile)
            showingImport = false
        } catch {
            importError = message(for: error)
        }
    }

    private func added(_ profile: Profile) {
        profiles = profileStore.loadAll()
        if activeProfileID == nil { activeProfileID = profile.id }
        if onboarding == .addProfile { onboarding = .routing }
    }

    func update(_ id: UUID) {
        guard let url = profileStore.subscriptionURL(of: id), var profile = profiles.first(where: { $0.id == id }), !updatingProfiles.contains(id) else { return }
        updatingProfiles.insert(id)
        notice = nil
        Task {
            defer { updatingProfiles.remove(id) }
            do {
                let response = try await SubscriptionFetcher().fetch(url)
                let result = try ConfigImporter.normalize(response.text)
                profile.nodeCount = result.nodeCount
                profile.updatedAt = .now
                profile.usage = response.usage ?? profile.usage
                try profileStore.save(profile, text: result.text)
                forgetEffective(id)
                profiles = profileStore.loadAll()
                if id == activeProfileID { await reloadRunningCore(closingConnections: true) }
            } catch {
                notice = String(localized: "“\(profile.name)”更新失败：\(message(for: error))")
            }
        }
    }

    func message(for error: Error) -> String {
        (error as? EditorError)?.message ?? error.localizedDescription
    }
}
