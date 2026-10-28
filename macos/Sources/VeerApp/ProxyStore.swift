import Foundation
import Observation
import VeerCore
import VeerProxy

/// Everything the windows and the menu bar show about the proxy, and the actions on it.
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
            case .rule: "规则"
            case .global: "全局"
            case .direct: "直连"
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

    var showingImport = false
    var importText = ""
    var importing = false
    var importError: String?

    var settings: RuntimeSettings { didSet { saveSettings() } }
    var startCoreAtLaunch: Bool { didSet { defaults.set(startCoreAtLaunch, forKey: "startCoreAtLaunch") } }
    var systemProxyWhenRunning: Bool { didSet { defaults.set(systemProxyWhenRunning, forKey: "systemProxyWhenRunning") } }

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var isRunning: Bool { phase == .running }

    // MARK: Dependencies

    let paths: VeerPaths
    let profileStore: ProfileStore
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
    @ObservationIgnored private var lastTotals: (upload: Int64, download: Int64)?

    init(paths: VeerPaths = VeerPaths(), systemProxy: SystemProxy = SystemProxy(), binary: URL? = ProxyStore.bundledCore, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.profileStore = ProfileStore(paths: paths)
        self.systemProxy = systemProxy
        self.binary = binary
        self.defaults = defaults
        settings = defaults.data(forKey: "runtimeSettings").flatMap { try? JSONDecoder().decode(RuntimeSettings.self, from: $0) } ?? RuntimeSettings()
        startCoreAtLaunch = defaults.object(forKey: "startCoreAtLaunch") as? Bool ?? true
        systemProxyWhenRunning = defaults.object(forKey: "systemProxyWhenRunning") as? Bool ?? false
        profiles = profileStore.loadAll()
        activeProfileID = defaults.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:)).flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
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
        if startCoreAtLaunch, activeProfile != nil { start() }
    }

    /// When Veer last quit without cleaning up, the system proxy still points at its port with
    /// nothing listening, and every app loses the network. Turn it off; a port another app
    /// listens on is that app's and stays.
    private func recoverStaleSystemProxy() {
        let port = settings.mixedPort
        guard !Ports.inUse(port), (try? systemProxy.isEnabled(host: "127.0.0.1", port: port)) == true else { return }
        try? systemProxy.disable(host: "127.0.0.1", port: port)
    }

    func start() {
        guard phase != .starting, phase != .running else { return }
        notice = nil
        guard let profile = activeProfile else { return }
        guard let binary else {
            phase = .failed("应用包里缺少 Mihomo 内核，请重新安装 Veer。", log: [])
            return
        }
        guard !Ports.inUse(settings.mixedPort) else {
            phase = .failed("端口 \(settings.mixedPort) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。", log: [])
            return
        }
        phase = .starting
        Task {
            do {
                try paths.prepare()
                guard let port = Ports.free() else { throw EditorError("找不到可用的本机端口来控制内核。") }
                let secret = RuntimeConfig.makeSecret()
                let yaml = try RuntimeConfig.build(profile: try profileStore.text(of: profile.id), settings: settings, controllerPort: port, secret: secret)
                try Data(yaml.utf8).write(to: paths.runtimeConfig, options: .atomic)
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
                    phase = .failed("内核在 60 秒内没有就绪，可能正在下载 GeoIP 数据或网络不通。", log: core.tail)
                    return
                }
                phase = .running
                await refresh()
                startTraffic()
                if systemProxyWhenRunning { setSystemProxy(true) }
            } catch {
                core?.stop()
                phase = .failed(message(for: error), log: core?.tail ?? [])
            }
        }
    }

    func stop() {
        if systemProxyOn { setSystemProxy(false) }
        trafficTask?.cancel()
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
        if systemProxyOn { try? systemProxy.disable(host: "127.0.0.1", port: proxyPort) }
        core?.stop()
    }

    private func coreExited(status: Int32, log: [String]) {
        guard core != nil else { return }
        if systemProxyOn { setSystemProxy(false) }
        trafficTask?.cancel()
        core = nil
        controller = nil
        controllerAccess = nil
        runningPort = nil
        groups = []
        uploadRate = 0
        downloadRate = 0
        let reason = log.last { $0.contains("level=fatal") || $0.contains("level=error") }.map(Self.logMessage)
        phase = .failed(reason.map { "内核退出了：\($0)" } ?? "内核意外退出（状态 \(status)）。", log: log)
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
            do { try await controller.select(member, in: group) } catch { notice = message(for: error) }
            await refresh()
        }
    }

    func testDelay(_ group: String) {
        guard let controller, !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        Task {
            do { _ = try await controller.testDelay(group: group) } catch {
                notice = "“\(group)”测速失败：\(message(for: error))"
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
            } catch { notice = message(for: error) }
        }
    }

    func setSystemProxy(_ on: Bool) {
        notice = nil
        do {
            if on {
                guard isRunning else { return }
                try systemProxy.enable(host: "127.0.0.1", port: proxyPort)
            } else {
                try systemProxy.disable(host: "127.0.0.1", port: proxyPort)
            }
            systemProxyOn = on
        } catch {
            notice = message(for: error)
        }
    }

    private func startTraffic() {
        trafficTask?.cancel()
        lastTotals = nil
        trafficTask = Task {
            while !Task.isCancelled, let controller {
                if let totals = try? await controller.trafficTotals() {
                    if let last = lastTotals {
                        uploadRate = max(0, totals.upload - last.upload)
                        downloadRate = max(0, totals.download - last.download)
                    }
                    lastTotals = totals
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Loads the active profile into the running core without restarting it.
    private func reloadRunningCore() async {
        guard isRunning, let controller, let access = controllerAccess, let profile = activeProfile else { return }
        do {
            var running = settings
            running.mixedPort = proxyPort
            let yaml = try RuntimeConfig.build(profile: try profileStore.text(of: profile.id), settings: running, controllerPort: access.port, secret: access.secret)
            try Data(yaml.utf8).write(to: paths.runtimeConfig, options: .atomic)
            try await controller.apply(yaml, mode: .config)
            await refresh()
        } catch {
            notice = message(for: error)
        }
    }

    // MARK: Profiles

    func activate(_ id: UUID) {
        guard id != activeProfileID else { return }
        activeProfileID = id
        if isRunning { Task { await reloadRunningCore() } } else if case .failed = phase { start() }
    }

    func delete(_ id: UUID) {
        if id == activeProfileID {
            stop()
            activeProfileID = profiles.first { $0.id != id }?.id
        }
        profileStore.delete(id)
        profiles = profileStore.loadAll()
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
                    let profile = Profile(name: response.title ?? url.host() ?? "订阅", isSubscription: true, nodeCount: result.nodeCount, usage: response.usage)
                    try profileStore.save(profile, text: result.text)
                    try profileStore.setSubscriptionURL(url, for: profile.id)
                    added(profile)
                } else {
                    let result = try ConfigImporter.normalize(input)
                    let profile = Profile(name: "粘贴的配置", isSubscription: false, nodeCount: result.nodeCount)
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
        if activeProfileID == nil {
            activeProfileID = profile.id
            if startCoreAtLaunch { start() }
        }
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
                profiles = profileStore.loadAll()
                if id == activeProfileID { await reloadRunningCore() }
            } catch {
                notice = "“\(profile.name)”更新失败：\(message(for: error))"
            }
        }
    }

    func message(for error: Error) -> String {
        (error as? EditorError)?.message ?? error.localizedDescription
    }
}
