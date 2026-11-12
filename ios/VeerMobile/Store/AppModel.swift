import Foundation
import Observation
import VeerCore
import VeerMobileKit
import VeerProxy

/// The app's two stores, made once. `ProxyStore` owns profiles and the in-process core;
/// `AgentStore` (the Mac file, compiled as is) edits routing through it.
///
/// Fixture mode (`FixtureAI.requested()`, e.g. `simulator launch … --env VEER_FIXTURE_AI=1`) runs the
/// Agent against `FixtureAITransport` with an in-memory key and its own settings domain, so
/// nothing reaches a real AI service, the Keychain or the user's saved settings.
@Observable
final class AppModel {
    let proxy: ProxyStore
    let agent: AgentStore
    let fixture: Bool
    /// App-wide sheets (spec §5): any tab can open them.
    var showingSettings = false
    var showingImport = false

    init(fixture: Bool = FixtureAI.requested(), fixturePaths: VeerPaths? = nil,
         fixtureDefaults: UserDefaults? = nil, core: any ProxyCore = MihomoInProcessCore.shared) {
        self.fixture = fixture
        let fixtureSecrets = MemoryKeyStore([FixtureAI.settings.provider.rawValue: FixtureAI.key])
        let defaults: UserDefaults
        let proxy: ProxyStore
        if fixture {
            // Separate files, preferences and memory-only credentials before either store is
            // initialized. A demonstration must never migrate or edit the ordinary app's data.
            defaults = fixtureDefaults ?? UserDefaults(suiteName: "veer.fixture") ?? UserDefaults()
            let paths = fixturePaths ?? VeerPaths(root: VeerPaths.defaultRoot.deletingLastPathComponent()
                .appendingPathComponent("VeerPrototypeFixture", isDirectory: true))
            proxy = ProxyStore(paths: paths, core: core, defaults: defaults, secrets: fixtureSecrets)
        } else {
            defaults = .standard
            proxy = ProxyStore(core: core)
        }
        let core = proxy.core
        let validator = MihomoValidator(check: { core.validate(yaml: $0) }, version: core.version)
        let geo = GeoDataStore.shared
        if fixture {
            let settings = FixtureAI.settings
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "aiSettings") }
            defaults.set(true, forKey: "useAI")
            let engine = EditorEngine(ai: AIClient(transport: FixtureAITransport()), validator: validator,
                                      verifier: FixtureRuleVerifier(), searcher: FixtureRuleSearch())
            agent = AgentStore(proxy: proxy, keyStore: fixtureSecrets,
                               engine: engine, defaults: defaults,
                               modelClient: AIClient(transport: FixtureAITransport()))
        } else {
            let engine = EditorEngine(validator: validator, searcher: WebSearchService(geo: geo),
                                      lookup: InstructionLookup(geo: geo), checker: DomainChecker(geo: geo))
            agent = AgentStore(proxy: proxy, engine: engine)
        }
        self.proxy = proxy
    }

    /// Verification hooks for the Simulator (launch arguments, never shown in the UI):
    /// `-VeerImportSample YES` imports the bundled DIRECT sample, `-VeerAutoStart YES` starts the core.
    func applyLaunchArguments(defaults: UserDefaults = .standard) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if defaults.bool(forKey: "VeerImportSample") || environment["VEER_IMPORT_SAMPLE"] == "1" { proxy.importSample() }
        if (defaults.bool(forKey: "VeerAutoStart") || environment["VEER_AUTO_START"] == "1"), proxy.activeProfile != nil { proxy.start() }
        #endif
    }
}
