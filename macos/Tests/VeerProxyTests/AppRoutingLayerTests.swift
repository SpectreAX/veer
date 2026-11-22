import Foundation
import Testing
@testable import VeerCore
@testable import VeerProxy
import Yams

struct AppRoutingLayerTests {
    static let chrome = AppIdentity(kind: .bundle, name: "Google Chrome", bundleID: "com.google.Chrome",
                                    bundlePath: "/Applications/Google Chrome.app",
                                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", flavor: .chromium)
    static let curl = AppIdentity(kind: .executable, name: "curl", executablePath: "/usr/bin/curl", flavor: .commandLine)

    static func rules(of text: String) throws -> [String] {
        guard case .mapping(let mapping)? = try Yams.compose(yaml: text), case .sequence(let rules)? = mapping[Node("rules")] else { return [] }
        return rules.compactMap(\.string)
    }

    @Test func appRulesGoAheadOfEditsAndProfileRules() throws {
        let base = RoutingLayerTests.profile
        let edit = try RoutingLayerTests.edit("a 走美国", on: base) { document in
            [.route(matchType: "DOMAIN-SUFFIX", match: "a.example", targetId: document.target(named: "美国")!.id)]
        }
        let layer = RoutingLayer(edits: [edit], appRules: [AppRule(app: Self.chrome, target: .policy("日本"))])
        let effective = try layer.apply(to: base)
        let rules = try Self.rules(of: effective.text)
        let guards = AppRuleBuilder.localRanges.count + AppRuleBuilder.localRanges6.count
        #expect(rules.prefix(guards).allSatisfy { $0.hasSuffix(",DIRECT,no-resolve") })
        #expect(rules[guards] == "PROCESS-PATH-WILDCARD,/Applications/Google Chrome.app/*,日本")
        #expect(rules[guards + 1] == "DOMAIN-SUFFIX,a.example,美国")
        #expect(rules.last == "MATCH,节点选择")
        #expect(effective.appRouting?.status(of: layer.appRules[0].id) == .active)
    }

    @Test func excludedTargetsAreReportedAndConfigStillLoads() throws {
        // A node the user unchecked is no longer an exit; the rule is left out, not sent DIRECT.
        let layer = RoutingLayer(excludedNodes: ["🇺🇸 洛杉矶 01"], appRules: [AppRule(app: Self.curl, target: .policy("🇺🇸 洛杉矶 01"))])
        let effective = try layer.apply(to: RoutingLayerTests.profile)
        #expect(effective.appRouting?.status(of: layer.appRules[0].id) == .missingTargets(["🇺🇸 洛杉矶 01"]))
        #expect(try !Self.rules(of: effective.text).contains { $0.contains("PROCESS-") })
    }

    @Test func runtimeConfigKeepsVeersLeadingRulesFirst() throws {
        let layer = RoutingLayer(appRules: [AppRule(app: Self.curl, target: .reject)])
        let effective = try layer.apply(to: RoutingLayerTests.profile)
        var settings = RuntimeSettings()
        settings.disableQUIC = true
        let hot = HotRuleSets.forProfile(effective.text)
        let built = try RuntimeConfig.build(profile: effective.text, settings: settings, controllerPort: 9, secret: "s", hot: hot)
        let rules = try Self.rules(of: built)
        #expect(rules.first == RuntimeConfig.quicRule)
        let firstApp = try #require(rules.firstIndex(of: "PROCESS-PATH,/usr/bin/curl,REJECT"))
        let lastHot = try #require(rules.lastIndex { $0.hasPrefix("RULE-SET,veer-hot-") })
        #expect(lastHot < firstApp)
        #expect(built.contains("find-process-mode: \"always\""))
    }

    @Test func layersFromBeforeAppRoutingStillLoad() throws {
        let old = #"{"edits":[],"excludedNodes":["a"],"regionMarks":{}}"#
        let layer = try JSONDecoder().decode(RoutingLayer.self, from: Data(old.utf8))
        #expect(layer.appRules.isEmpty)
        #expect(!RoutingLayer(appRules: [AppRule(app: Self.curl, target: .direct)]).isEmpty)
        let config = try JSONDecoder().decode(EffectiveConfig.self, from: Data(#"{"text":"a: 1","emptiedGroups":[],"keptNodes":[]}"#.utf8))
        #expect(config.appRouting == nil)
    }

    @Test func blockStyleFlowStyleAndMissingRulesAllTakeTheBlock() throws {
        let lines = ["PROCESS-PATH,/usr/bin/curl,DIRECT", "PROCESS-PATH-WILDCARD,/Applications/It's.app/*,DIRECT"]
        let block = "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        #expect(try Self.rules(of: AppRuleBlock.prepend(lines, to: block)) == lines + ["MATCH,DIRECT"])
        let flow = "proxies: []\nrules: ['MATCH,DIRECT']\n"
        #expect(try Self.rules(of: AppRuleBlock.prepend(lines, to: flow)) == lines + ["MATCH,DIRECT"])
        #expect(try Self.rules(of: AppRuleBlock.prepend(lines, to: "proxies: []\n")) == lines)
    }

    // MARK: Discovery

    static func makeBundle(_ name: String, in folder: URL, id: String, electron: Bool = false) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try executable(at: macOS.appendingPathComponent(name))
        if electron {
            try fm.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
            let helper = app.appendingPathComponent("Contents/Frameworks/\(name) Helper (Renderer).app")
            try fm.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let helperPlist: [String: Any] = ["CFBundleIdentifier": id + ".helper", "CFBundleExecutable": "\(name) Helper (Renderer)"]
            try PropertyListSerialization.data(fromPropertyList: helperPlist, format: .xml, options: 0)
                .write(to: helper.appendingPathComponent("Contents/Info.plist"))
            try executable(at: helper.appendingPathComponent("Contents/MacOS/\(name) Helper (Renderer)"))
        }
        return app
    }

    static func executable(at url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func discoveryReadsBundlesHelpersAndRealPaths() throws {
        // Under /tmp, which is a link to /private/tmp: the kernel reports the /private path.
        let root = URL(fileURLWithPath: "/tmp/veer-app-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Vendor"), withIntermediateDirectories: true)
        let app = try Self.makeBundle("Chatty", in: folder, id: "com.example.chatty", electron: true)
        _ = try Self.makeBundle("Nested", in: folder.appendingPathComponent("Vendor"), id: "com.example.nested")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Deep/Er"), withIntermediateDirectories: true)
        _ = try Self.makeBundle("TooDeep", in: folder.appendingPathComponent("Deep/Er"), id: "com.example.deep")

        let found = AppDiscovery.bundleURLs(in: [folder]).map(\.lastPathComponent).sorted()
        #expect(found == ["Chatty.app", "Nested.app"])
        let identity = try #require(AppDiscovery.identity(ofBundle: app))
        #expect(identity.bundleID == "com.example.chatty")
        #expect(identity.bundlePath?.hasPrefix("/private/tmp/") == true)
        #expect(identity.flavor == .electron)
        #expect(identity.helpers.map(\.name) == ["Chatty Helper (Renderer)"])
        #expect(identity.helpers.allSatisfy { identity.owns(processPath: $0.path) })

        // A link to a tool resolves to the file itself, as a Homebrew link does.
        let tool = root.appendingPathComponent("tool-1.2")
        try Self.executable(at: tool)
        let link = root.appendingPathComponent("tool")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        #expect(AppDiscovery.identity(ofPicked: link)?.executablePath == "/private" + tool.path)
        #expect(AppDiscovery.identity(ofPicked: root) == nil)
    }

    @Test func catalogReadsOnlyChangedBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try Self.makeBundle("One", in: folder, id: "com.example.one")
        let store = AppCatalogStore(paths: VeerPaths(root: root))
        #expect(store.cached().isEmpty)
        #expect(store.scan(folders: [folder]).map(\.name) == ["One"])
        // Changed on disk but not in Info.plist: the cached entry stands.
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/One"))
        #expect(store.scan(folders: [folder]).first?.name == "One")
        #expect(store.cached().map(\.name) == ["One"])
    }
}

/// Runs only when VEER_MIHOMO_BIN points at a Mihomo binary: the bundled core accepts every rule form.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct AppRoutingMihomoTests {
    @Test func everyGeneratedFormPassesMihomo() async throws {
        let odd = AppIdentity(kind: .executable, name: "odd", executablePath: "/opt/a,b (beta)/run*")
        let cafe = AppIdentity(kind: .bundle, name: "Café", bundlePath: "/Applications/Caf\u{E9} (β), it's.app",
                               executablePath: "/Applications/Caf\u{E9} (β), it's.app/Contents/MacOS/x")
        let layer = RoutingLayer(appRules: [
            AppRule(app: AppRoutingLayerTests.chrome, target: .policy("日本"),
                    domains: [.init(matchType: "DOMAIN-SUFFIX", value: "bank.example", target: .direct),
                              .init(matchType: "DOMAIN-KEYWORD", value: "ads", target: .reject)]),
            AppRule(app: AppRoutingLayerTests.curl, target: .policy("🇯🇵 东京 01")),
            AppRule(app: odd, target: .reject, domains: [.init(matchType: "DOMAIN", value: "x.example", target: .direct)]),
            AppRule(app: cafe, target: .policy("节点选择"), domains: [.init(matchType: "DOMAIN", value: "y.example", target: .reject)]),
        ])
        let effective = try layer.apply(to: RoutingLayerTests.profile)
        #expect(effective.appRouting?.lines.count ?? 0 > 10)
        let built = try RuntimeConfig.build(profile: effective.text, settings: RuntimeSettings(), controllerPort: 9, secret: "s")
        let check = await MihomoValidator().validate(built)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }
}
