import Foundation
import Testing
@testable import VeerMobile
import VeerCore
import VeerMobileKit
import VeerProxy
import Yams

@MainActor
struct ProxyStoreIsolationTests {
    @Test
    func defaultSettingsNeverEnableDeviceWideFeatures() {
        let settings = ProxyStore.defaultSettings
        #expect(!settings.tun)
        #expect(!settings.allowLAN)
        #expect(!settings.processMatching)
    }

    @Test
    func initializationOnlyReadsItsIsolatedStorage() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        #expect(!sandbox.paths.usesKeychain(team: "iOS", environment: [:]))
        let core = NeverRunningCore()
        let store = ProxyStore(paths: sandbox.paths, core: core, defaults: sandbox.defaults, secrets: sandbox.secrets)
        #expect(store.profiles.isEmpty)
        #expect(store.activeProfileID == nil)
        #expect(store.phase == .stopped)
        #expect(store.settings == ProxyStore.defaultSettings)
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.root.path))
        #expect(sandbox.defaults.string(forKey: ProxyStore.Keys.activeProfile) == nil)
    }

    @Test
    func bundledDirectSampleImportIsIdempotentAndSurvivesReload() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let core = NeverRunningCore()
        let store = ProxyStore(paths: sandbox.paths, core: core, defaults: sandbox.defaults, secrets: sandbox.secrets)
        let bundled = try #require(ProxyStore.sampleProfileURL)
        #expect(bundled.lastPathComponent == "Sample-Direct.yaml")
        #expect(store.importSample())
        #expect(store.importError == nil)
        let sample = try #require(store.sampleProfile)
        #expect(store.profiles.count == 1)
        #expect(store.activeProfileID == sample.id)
        #expect(sample.name == ProxyStore.sampleProfileName)
        #expect(!sample.isSubscription)
        #expect(sample.nodeCount == 2)
        #expect(store.profileStore.subscriptionURL(of: sample.id) == nil)
        #expect(sandbox.defaults.string(forKey: ProxyStore.Keys.activeProfile) == sample.id.uuidString)
        #expect(store.profileStore.secrets is MemoryKeyStore)

        let text = try store.profileStore.text(of: sample.id)
        let yaml = try #require(try Yams.load(yaml: text) as? [String: Any])
        let nodes = try #require(yaml["proxies"] as? [[String: Any]])
        #expect(nodes.count == 2)
        for node in nodes {
            #expect(node["type"] as? String == "direct")
            for key in ["server", "password", "uuid", "token"] { #expect(node[key] == nil) }
        }
        #expect(yaml["proxy-providers"] == nil)
        let savedIndex = try Data(contentsOf: sandbox.paths.profileIndex)
        let savedFiles = try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.profiles.path).sorted()

        // A second import is a selection, not another read/import, even with no source URL.
        store.activeProfileID = nil
        #expect(store.importSample(from: nil))
        #expect(store.activeProfileID == sample.id)
        #expect(store.profiles.map(\.id) == [sample.id])
        #expect(try store.profileStore.text(of: sample.id) == text)
        #expect(try Data(contentsOf: sandbox.paths.profileIndex) == savedIndex)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.profiles.path).sorted() == savedFiles)

        let reloaded = ProxyStore(paths: sandbox.paths, core: core, defaults: sandbox.defaults, secrets: sandbox.secrets)
        #expect(reloaded.activeProfileID == sample.id)
        #expect(reloaded.sampleProfile?.id == sample.id)
        #expect(reloaded.importSample())
        #expect(reloaded.profiles.count == 1)
        #expect(reloaded.phase == .stopped)
        #expect(store.phase == .stopped)
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.runtimeConfig.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.secrets.path))
    }

    @Test
    func separateStoresCannotSeeEachOthersProfilesOrPreferences() throws {
        let first = try Sandbox()
        let second = try Sandbox()
        defer { first.cleanUp(); second.cleanUp() }
        let store = ProxyStore(paths: first.paths, core: NeverRunningCore(), defaults: first.defaults, secrets: first.secrets)
        #expect(store.importSample())
        let other = ProxyStore(paths: second.paths, core: NeverRunningCore(), defaults: second.defaults, secrets: second.secrets)
        #expect(first.paths.root != second.paths.root)
        #expect(other.profiles.isEmpty)
        #expect(other.activeProfileID == nil)
        #expect(second.defaults.string(forKey: ProxyStore.Keys.activeProfile) == nil)
        #expect(!FileManager.default.fileExists(atPath: second.paths.root.path))
    }

    @Test
    func missingSampleFailsWithoutCreatingProfilesOrStartingCore() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let store = ProxyStore(paths: sandbox.paths, core: NeverRunningCore(), defaults: sandbox.defaults, secrets: sandbox.secrets)
        #expect(!store.importSample(from: nil))
        #expect(store.importError?.isEmpty == false)
        #expect(store.profiles.isEmpty)
        #expect(store.activeProfileID == nil)
        #expect(store.phase == .stopped)
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.root.path))
    }

    @Test
    func fixtureModelListingCannotBecomeLiveAfterChangingEndpoint() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let model = AppModel(fixture: true, fixturePaths: sandbox.paths,
                             fixtureDefaults: sandbox.defaults, core: NeverRunningCore())
        let proxy = model.proxy
        let agent = model.agent
        // A realistic HTTPS endpoint shape on a reserved domain, never a real AI service.
        agent.settings.baseURL = "https://api.example.invalid/v1"
        agent.settings.model = "configured-service-model"
        await #expect(throws: AIFailure.network) { try await agent.fetchModels() }
        #expect(agent.settings.fetchedModels.isEmpty)
        #expect(agent.keyStore is MemoryKeyStore)
        #expect(agent.defaults === sandbox.defaults)
        #expect(proxy.phase == .stopped)
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.root.path))
    }

    @Test
    func appModelConfiguresIsolatedFilesPreferencesAndMemoryKeysBeforeLoadingStores() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let profile = Profile(name: "Isolated test profile", isSubscription: false, nodeCount: 0)
        let text = "proxies: []\nrules: ['MATCH,DIRECT']\n"
        try ProfileStore(paths: sandbox.paths, secrets: sandbox.secrets).save(profile, text: text)
        var session = Session(title: "Only in this temporary root", source: .sample, text: text)
        session.profileID = profile.id
        try SessionStore(directory: sandbox.paths.threads).save(session)
        sandbox.defaults.set(profile.id.uuidString, forKey: ProxyStore.Keys.activeProfile)
        sandbox.defaults.set(false, forKey: "useAI")
        let previousSettings = AISettings(provider: .custom, baseURL: "https://previous.example.invalid/v1", model: "not-fixture")
        sandbox.defaults.set(try JSONEncoder().encode(previousSettings), forKey: "aiSettings")

        let model = AppModel(fixture: true, fixturePaths: sandbox.paths,
                             fixtureDefaults: sandbox.defaults, core: NeverRunningCore())
        #expect(model.fixture)
        #expect(model.proxy.paths.root == sandbox.paths.root)
        #expect(model.proxy.profiles.map(\.id) == [profile.id])
        #expect(model.proxy.activeProfileID == profile.id)
        #expect(model.agent.proxy === model.proxy)
        #expect(model.agent.sessionStore.directory == sandbox.paths.threads)
        #expect(model.agent.sessions.map(\.id) == [session.id])
        #expect(model.agent.defaults === sandbox.defaults)
        #expect(model.agent.useAI)
        #expect(model.agent.settings == FixtureAI.settings)
        #expect(model.agent.keySaved)
        let proxyKeys = try #require(model.proxy.profileStore.secrets as? MemoryKeyStore)
        let agentKeys = try #require(model.agent.keyStore as? MemoryKeyStore)
        #expect(proxyKeys === agentKeys)
        #expect(agentKeys.read(for: FixtureAI.settings.provider.rawValue) == FixtureAI.key)
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.secrets.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.paths.runtimeConfig.path))
        #expect(model.proxy.phase == .stopped)
        let reloadedSettings = try JSONDecoder().decode(AISettings.self, from: #require(sandbox.defaults.data(forKey: "aiSettings")))
        #expect(reloadedSettings == FixtureAI.settings)
    }

    /// Fresh names for every test invocation; never fall back to standard defaults or default paths.
    private struct Sandbox {
        let paths: VeerPaths
        let defaults: UserDefaults
        let secrets = MemoryKeyStore()
        let suite: String

        init() throws {
            let name = "VeerMobileTests.\(UUID().uuidString)"
            suite = name
            paths = VeerPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
            defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: paths.root)
        }
    }
}

/// A tripwire, not a running core: no sockets, subprocesses, or real validation calls.
private struct NeverRunningCore: ProxyCore {
    var version: String { "test-core-never-started" }
    func start(home: URL, config: URL) throws {
        Issue.record("A storage-only test unexpectedly attempted to start the core")
        throw ProxyCoreError(message: "Core startup is forbidden in unit tests")
    }
    func stop() { Issue.record("A storage-only test unexpectedly attempted to stop the core") }
    func setMode(_ mode: String) throws {
        Issue.record("A storage-only test unexpectedly attempted to switch the core's mode")
        throw ProxyCoreError(message: "Core mode changes are forbidden in unit tests")
    }
    func reload(config: URL) throws {
        Issue.record("A storage-only test unexpectedly attempted to reload the core")
        throw ProxyCoreError(message: "Core reload is forbidden in unit tests")
    }
    func validate(yaml: Data) -> String? {
        Issue.record("A storage-only test unexpectedly attempted core validation")
        return "Core validation is forbidden in storage-only tests"
    }
}
