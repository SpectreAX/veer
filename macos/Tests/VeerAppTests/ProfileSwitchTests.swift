import Foundation
import Network
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

/// Profile switching on the real `ProxyStore` with the bundled Mihomo (`VEER_MIHOMO_BIN`), on this
/// Mac only: nodes are HTTP proxies on 127.0.0.1 that answer every delay test themselves, the core
/// has its own folder, free ports and `dns.enable: false`, the system proxy is a stub that throws,
/// and the exit check is off. Nothing leaves this Mac and no system setting changes.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct ProfileSwitchTests {
    /// An HTTP proxy that accepts CONNECT and answers the request inside the tunnel with 204.
    final class MockNode: @unchecked Sendable {
        let listener: NWListener
        let delay: Duration
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init(delay: Duration = .milliseconds(20)) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            self.delay = delay
            listener.newConnectionHandler = { [delay] connection in
                connection.start(queue: .global())
                Self.serve(connection, delay: delay, established: false)
            }
        }

        func start() async throws {
            listener.start(queue: .global())
            for _ in 0..<200 where listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }

        func stop() { listener.cancel() }

        static func serve(_ connection: NWConnection, delay: Duration, established: Bool, buffer: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                var buffer = buffer + (data ?? Data())
                guard error == nil, !(done && data == nil) else { return connection.cancel() }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    return serve(connection, delay: delay, established: established, buffer: buffer)
                }
                buffer.removeSubrange(..<end.upperBound)
                let reply = established ? "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" : "HTTP/1.1 200 Connection established\r\n\r\n"
                DispatchQueue.global().asyncAfter(deadline: .now() + (established ? 0 : Double(delay.components.attoseconds) / 1e18)) {
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                        serve(connection, delay: delay, established: true, buffer: buffer)
                    })
                }
            }
        }
    }

    /// A port for the core or a dead node, as the store picks the controller's: below the ephemeral
    /// range, so a suite starting listeners or connections in parallel can't take it first.
    static func freePort() -> Int { Ports.free() ?? 0 }

    /// A profile of `count` nodes named `prefix…`, plus one whose port nothing listens on.
    static func profile(_ prefix: String, nodes: [MockNode], dead: Int) -> (text: String, names: [String]) {
        var names = nodes.indices.map { "\(prefix)\(String(format: "%02d", $0))" }
        var lines = ["dns:", "  enable: false", "proxies:"]
        lines += zip(names, nodes).map { "  - {name: \($0), type: http, server: 127.0.0.1, port: \($1.port)}" }
        lines.append("  - {name: \(prefix)-dead, type: http, server: 127.0.0.1, port: \(dead)}")
        names.append("\(prefix)-dead")
        lines += ["proxy-groups:", "  - {name: \(prefix)-Select, type: select, proxies: [\(names.joined(separator: ", "))]}",
                  "rules:", "  - MATCH,\(prefix)-Select"]
        return (lines.joined(separator: "\n") + "\n", names)
    }

    struct Rig {
        let store: ProxyStore
        let first: Profile, second: Profile
        let aNames: [String], bNames: [String]
        let nodes: [MockNode]
    }

    static func rig(nodeDelay: Duration = .milliseconds(20), slowNodeDelay: Duration? = nil) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-switch-\(UUID().uuidString)")
        let paths = VeerPaths(root: root)
        try paths.prepare()
        let nodes = try (0..<16).map { index in try MockNode(delay: index == 7 ? slowNodeDelay ?? nodeDelay : nodeDelay) }
        for node in nodes { try await node.start() }
        let dead = freePort()
        let (aText, aNames) = profile("A", nodes: Array(nodes[0..<8]), dead: dead)
        let (bText, bNames) = profile("B", nodes: Array(nodes[8..<16]), dead: dead)
        let profiles = ProfileStore(paths: paths, secrets: FileKeyStore(url: paths.secrets))
        let first = Profile(name: "A", isSubscription: false, nodeCount: aNames.count)
        let second = Profile(name: "B", isSubscription: false, nodeCount: bNames.count)
        try profiles.save(first, text: aText)
        try profiles.save(second, text: bText)
        let defaults = UserDefaults(suiteName: "veer-switch-\(UUID().uuidString)")!
        defaults.set(false, forKey: "showExitIP")
        defaults.set(first.id.uuidString, forKey: "activeProfile")
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"]!)
        let store = ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in throw EditorError("System proxy forbidden in tests") }),
                               binary: binary, defaults: defaults)
        var settings = store.settings
        settings.mixedPort = freePort()
        settings.tun = false
        store.settings = settings
        store.delayURL = "http://127.0.0.1:9/generate_204"
        return Rig(store: store, first: first, second: second, aNames: aNames, bNames: bNames, nodes: nodes)
    }

    /// Waits for `condition`. On a timeout the error names the stage and, with a store, what the core,
    /// the switch, the running tests and each expected node were doing, so a failure says which part
    /// never finished instead of only that it timed out.
    static func waitUntil(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
        try await waitUntil("", seconds: seconds, condition)
    }

    static func waitUntil(_ stage: String, seconds: Double = 20, in store: ProxyStore? = nil, names: [String] = [],
                          _ condition: () -> Bool) async throws {
        let begun = Date(), end = begun.addingTimeInterval(seconds)
        var early = ""
        while !condition() {
            // One second into a start that hasn't come up: the core's ports in the socket table, while
            // whatever held them may still be there.
            if early.isEmpty, let store, store.phase == .starting, Date().timeIntervalSince(begun) > 1,
               let controllerPort = store.controller?.base.port {
                early = "at 1 s: " + [store.settings.mixedPort, controllerPort].map { "\($0): " + sockets(on: $0) }.joined(separator: " ; ")
            }
            guard Date() < end else {
                var state = store.map { describe($0, names: names) } ?? ""
                if let store { state += " " + (await probeCore(store)) + " [\(early)]" }
                let what = stage.isEmpty ? "condition" : stage
                throw EditorError("timed out waiting \(String(format: "%.0f", seconds)) s for \(what)\(state.isEmpty ? "" : ": " + state)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// What the core itself says at a timeout, as the start's readiness check asks it: whether its
    /// rule sets and node lists have loaded, and whether a tunnel through its port stays open.
    static func probeCore(_ store: ProxyStore) async -> String {
        guard let controller = store.controller, let port = controller.base.port else { return "core=[no controller]" }
        let providers: String
        do {
            let loaded = try await controller.providersLoaded()
            let rules = try await controller.ruleProviders(), nodes = try await controller.proxyProviders()
            providers = "loaded=\(loaded) rules=\(rules.count) nodeLists=\(nodes.map { "\($0.key):\($0.value.vehicleType ?? "-"):\($0.value.loaded)" })"
        } catch {
            providers = "providers error: \(error)"
        }
        let proxyPort = store.settings.mixedPort
        let tunnel = await Task.detached { TunnelProbe.ask(proxyPort: proxyPort, controllerPort: port) }.value
        // The process's last lines, read by reflection: the store keeps the core private.
        let process = Mirror(reflecting: store).children.first { $0.label == "core" || $0.label == "_core" }?.value as? CoreProcess
        let tail = process?.tail.suffix(12).joined(separator: " | ") ?? "no core process"
        // Who holds a port the core could not bind.
        var holders: [String] = []
        let lines = process?.tail ?? []
        for line in lines where line.contains("address already in use") {
            guard let range = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) else { continue }
            let port = line[range].split(separator: ":").last.map(String.init) ?? ""
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-nP", "-iTCP:\(port)"]
            let pipe = Pipe()
            lsof.standardOutput = pipe
            try? lsof.run()
            lsof.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Kernel-held states (TIME_WAIT and the like) have no process, so lsof can't show them.
            let held = output.split(separator: "\n").dropFirst().joined(separator: " / ")
            holders.append("\(port): lsof=\(held) netstat=" + sockets(on: Int(port) ?? 0))
        }
        return "core=[\(providers) tunnel=\(tunnel)] holders=[\(holders.joined(separator: " ; "))] log=[\(tail)]"
    }

    /// Lines of `netstat -anp tcp` with `port` on 127.0.0.1, every state included.
    static func sockets(on port: Int) -> String {
        let netstat = Process()
        netstat.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        netstat.arguments = ["-anp", "tcp"]
        let pipe = Pipe()
        netstat.standardOutput = pipe
        try? netstat.run()
        let table = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        netstat.waitUntilExit()
        let lines = table.split(separator: "\n").filter { $0.contains("127.0.0.1.\(port) ") }
            .map { $0.split(separator: " ").joined(separator: " ") }
        return lines.isEmpty ? "none" : lines.joined(separator: " / ")
    }

    /// The store's switching and testing state, and every expected node's result, for a timeout.
    static func describe(_ store: ProxyStore, names: [String]) -> String {
        let profile = { (id: UUID?) in id.flatMap { id in store.profiles.first { $0.id == id }?.name } ?? "none" }
        let nodes = names.map { name -> String in
            let state = store.delays[name].map { "\($0)" } ?? "nil"
            return "\(name)=\(state)"
        }
        return "phase=\(store.phase) running=\(store.isRunning) active=\(profile(store.activeProfileID)) switchingTo=\(profile(store.switchingTo)) "
            + "groups=\(store.groups.map(\.name)) latencyRuns=\(store.latencyRuns.keys.map { "\($0)" }) testingScopes=\(store.testingScopes.map { "\($0)" }) "
            + "notice=\(store.notice ?? "nil") settled=\(settled(store)) tested=\(tested(store, names)) nodes=[\(nodes.joined(separator: ", "))] "
            + "startup=[\(store.startup?.report.replacingOccurrences(of: "\n", with: "; ") ?? "none")]"
    }

    static func settled(_ store: ProxyStore) -> Bool { store.switchingTo == nil && store.latencyRuns.isEmpty && !store.groups.isEmpty }

    static func tearDown(_ rig: Rig) {
        rig.store.stop()
        for node in rig.nodes { node.stop() }
        try? FileManager.default.removeItem(at: rig.store.paths.root)
    }

    /// Every node of the running profile got a real result: measured, or (for the dead one) a failure.
    static func tested(_ store: ProxyStore, _ names: [String]) -> Bool {
        names.allSatisfy { name in
            switch store.delays[name] {
            case .measured?: !name.hasSuffix("-dead")
            case .timedOut?, .failed?: name.hasSuffix("-dead")
            default: false
            }
        }
    }

    @Test func switchingBackAndForthTestsEveryNodeOfTheNewProfileAndNoneTimesOut() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil("start, first test", in: store, names: rig.aNames) {
            store.isRunning && Self.settled(store) && Self.tested(store, rig.aNames)
        }
        for (target, names, other) in [(rig.second, rig.bNames, rig.aNames), (rig.first, rig.aNames, rig.bNames), (rig.second, rig.bNames, rig.aNames)] {
            store.activate(target.id)
            #expect(store.switchingTo == target.id)
            try await Self.waitUntil("switch to \(target.name), its test", in: store, names: names) { Self.settled(store) && Self.tested(store, names) }
            #expect(store.activeProfileID == target.id)
            #expect(store.groups.map(\.name).contains("\(target.name)-Select"))
            #expect(other.allSatisfy { store.delays[$0] == nil }, "no result of the old profile is kept")
            #expect(store.notice == nil)
            let running = try await store.controller!.proxyNames()
            #expect(running.contains("\(target.name)-Select"))
        }
    }

    @Test func rapidSwitchingEndsOnTheLastClickInTheCoreAndThePage() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        for _ in 0..<3 {
            store.activate(rig.second.id)
            store.activate(rig.first.id)
        }
        store.activate(rig.second.id)
        try await Self.waitUntil { Self.settled(store) && Self.tested(store, rig.bNames) }
        #expect(store.activeProfileID == rig.second.id)
        let running = try await store.controller!.proxyNames()
        #expect(running.contains("B-Select") && !running.contains("A-Select"))
        #expect(store.groups.map(\.name) == ["B-Select"])
    }

    @Test func aTestStillRunningWhenTheProfileChangesWritesNothingIntoTheNewOne() async throws {
        let rig = try await Self.rig(nodeDelay: .milliseconds(600))
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil("start, first test", seconds: 30, in: store, names: rig.aNames) {
            store.isRunning && Self.settled(store) && Self.tested(store, rig.aNames)
        }
        store.testDelay("A-Select")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.testingScopes.contains(.group("A-Select")))
        store.activate(rig.second.id)
        try await Self.waitUntil("switch to B during A's test, B's test", seconds: 30, in: store, names: rig.bNames) {
            Self.settled(store) && Self.tested(store, rig.bNames)
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(rig.aNames.allSatisfy { store.delays[$0] == nil })
        #expect(!store.testingScopes.contains(.group("A-Select")))
        #expect(store.groups.first?.members.allSatisfy { $0.state != .cancelled && $0.state != .testing } == true)
    }

    @Test func aRegionTestMeasuresOnlyItsNodesAndDoesNotBlockASameNamedGroup() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        let group = "region:JP"
        let text = try store.profileStore.text(of: rig.first.id).replacingOccurrences(of: "A-Select", with: group)
        try store.profileStore.save(rig.first, text: text)
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) && Self.tested(store, rig.aNames) }

        let selected = try await store.controller?.selection(of: group)
        let previous = store.delayTimes
        let expected = Set(rig.aNames.prefix(2))
        store.regionMarks = Dictionary(uniqueKeysWithValues: rig.aNames.map { ($0, expected.contains($0) ? "JP" : "US") })
        let regions = NodeMapView.regions(in: store, matching: "")
        let regionNodes = try #require(regions["JP"]).map(\.name)
        #expect(Set(regionNodes) == expected)
        store.testNodes(regionNodes, scope: .region("JP"))
        try await Self.waitUntil { Self.settled(store) }
        #expect(Set(store.delayTimes.keys.filter { store.delayTimes[$0] != previous[$0] }) == Set(regionNodes))
        #expect(try await store.controller?.selection(of: group) == selected)

        store.testNodes(regionNodes, scope: .region("JP"))
        store.testDelay(group)
        #expect(store.latencyRuns.count == 2)
        #expect(store.testingScopes.contains(.region("JP")) && store.testingScopes.contains(.group(group)))
        try await Self.waitUntil { Self.settled(store) }
        #expect(try await store.controller?.selection(of: group) == selected)
        #expect(!store.systemProxyOn && !store.tunActive)
    }

    @Test func choosingFastestSkipsSlowProbesButAnExplicitGroupTestFinishesThem() async throws {
        let rig = try await Self.rig(slowNodeDelay: .milliseconds(600))
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) && Self.tested(store, rig.aNames) }
        store.resetDelays()
        let slow = rig.aNames[7]
        let partial = try await store.testNow("A-Select", reuseFresh: true)
        #expect(partial[rig.aNames[0], default: 0] > 0 || partial.values.contains(where: { $0 > 0 }))
        #expect(partial[slow] == nil)
        #expect(store.delays[slow] == .untested)
        let full = try await store.testNow("A-Select")
        #expect(full[slow, default: 0] > 0)
    }

    @Test func settingsReloadWaitsForThePendingProfileSwitch() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        let controller = try #require(store.controller)
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        store.coreConfigWork.add { for await _ in blocked {} }
        store.activate(rig.second.id)
        store.settings.logLevel = "warning"

        // Let the settings debounce fire while the switch is still waiting to run.
        try await Task.sleep(for: .milliseconds(1100))
        let waiting = try await controller.proxyNames()
        #expect(waiting.contains("A-Select") && !waiting.contains("B-Select"))

        release.finish()
        try await Self.waitUntil { store.switchingTo == nil }
        let switched = try await controller.proxyNames()
        #expect(switched.contains("B-Select") && !switched.contains("A-Select"))
        #expect(try String(contentsOf: store.paths.runtimeConfig, encoding: .utf8).contains("log-level: warning"))
    }

    @Test(arguments: [false, true])
    func aRefusedSubscriptionUpdateDoesNotUndoTheProfileSwitch(updateQueuedFirst: Bool) async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        let controller = try #require(store.controller)
        let text = try store.profileStore.text(of: rig.second.id)
        let invalid = text.replacingOccurrences(of: "MATCH,B-Select", with: "MATCH,Nowhere")
        let normalized = try ConfigImporter.normalize(invalid)
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        store.coreConfigWork.add { for await _ in blocked {} }
        if !updateQueuedFirst { store.activate(rig.second.id) }
        let update = Task { try await store.save(SubscriptionResponse(text: invalid, headers: [:]), normalized, into: rig.second, reimport: false) }

        // A completed download must wait its turn before replacing the selected profile on disk.
        try await Task.sleep(for: .milliseconds(100))
        if updateQueuedFirst { store.activate(rig.second.id) }
        #expect(try store.profileStore.text(of: rig.second.id) == text)
        release.finish()
        await #expect(throws: EditorError.self) { try await update.value }
        let running = try await controller.proxyNames()
        #expect(store.activeProfileID == rig.second.id)
        #expect(running.contains("B-Select") && !running.contains("A-Select"))
        #expect(try store.profileStore.text(of: rig.second.id) == text)
    }

    @Test func anEditToTheSelectedProfileDoesNotAffectTheCoreBeforeTheSwitch() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        let controller = try #require(store.controller)
        let set = try #require(store.hotSets?.set(for: "REJECT"))
        let ruleFile = store.paths.core.appendingPathComponent(set.path)
        let host = "pending-edit.example.test"
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        store.coreConfigWork.add { for await _ in blocked {} }
        store.activate(rig.second.id)
        try await store.addRule(matchType: "DOMAIN", value: host, target: "REJECT")

        try await Task.sleep(for: .milliseconds(100))
        #expect(try !String(contentsOf: ruleFile, encoding: .utf8).contains(host))
        #expect(try await controller.proxyNames().contains("A-Select"))
        release.finish()
        #expect(await store.layerApply?.value == .running)
        #expect(try await controller.proxyNames().contains("B-Select"))
        #expect(try await controller.rules().contains { $0.payload == host && $0.proxy == "REJECT" })
    }

    @Test func changingProfileWhileStartingUsesTheLastSelection() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        store.activate(rig.second.id)
        store.activate(rig.first.id)
        store.activate(rig.second.id)
        try await Self.waitUntil { store.isRunning && store.activeProfileID == rig.second.id && Self.settled(store) }
        let running = try await store.controller!.proxyNames()
        #expect(running.contains("B-Select") && !running.contains("A-Select"))
    }

    @Test func appRulesAndNodeEditsSurviveTheSameProfileSwitch() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        let controller = try #require(store.controller)
        let app = AppIdentity(kind: .executable, name: "Fixture", executablePath: "/usr/bin/true", flavor: .commandLine)
        let rule = AppRule(app: app, target: .reject, createdAt: Date(timeIntervalSince1970: 0))
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        store.coreConfigWork.add { for await _ in blocked {} }
        store.activate(rig.second.id)
        let appChange = Task { try await store.setAppRules([rule], for: rig.second.id) }
        let excluded = try #require(rig.bNames.last)
        store.setNode(excluded, included: false, in: rig.second.id)

        release.finish()
        _ = try await appChange.value
        await store.coreConfigWork.finish()
        let layer = store.layer(of: rig.second.id)
        #expect(layer.excludedNodes.contains(excluded))
        #expect(layer.appRules == [rule])
        let ruleList = try await controller.rules()
        #expect(ruleList.contains { $0.payload == app.executablePath && $0.proxy == "REJECT" })
    }

    @Test func aProfileTheCoreRefusesLeavesThePreviousOneRunning() async throws {
        let rig = try await Self.rig()
        defer { Self.tearDown(rig) }
        let store = rig.store
        // Valid YAML Mihomo will not load: a rule whose policy does not exist.
        let broken = Profile(name: "Broken", isSubscription: false, nodeCount: 1)
        let text = """
        dns:
          enable: false
        proxies:
          - {name: X, type: http, server: 127.0.0.1, port: 1}
        proxy-groups:
          - {name: G, type: select, proxies: [X]}
        rules:
          - MATCH,Nowhere

        """
        try store.profileStore.save(broken, text: text)
        store.profiles = store.profileStore.loadAll()
        store.start()
        try await Self.waitUntil { store.isRunning && Self.settled(store) }
        store.activate(broken.id)
        try await Self.waitUntil { store.switchingTo == nil && store.activeProfileID == rig.first.id && !store.groups.isEmpty }
        #expect(store.notice?.contains("Broken") == true)
        let running = try await store.controller!.proxyNames()
        #expect(running.contains("A-Select") && !running.contains("G"))
        #expect(store.isRunning)
    }
}

/// Routing changes on the real core: which connections move, and how long each path takes.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct RoutingChangeTests {
    typealias Rig = ProfileSwitchTests.Rig

    /// A tunnel through the core's mixed port to `host`, held open; the mock node answers it.
    static func tunnel(to host: String, port: Int) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: .global())
        let request = "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n"
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
        return connection
    }

    @Test func aNewConnectionUsesTheSelectedNodeAfterTheControllerConfirmsIt() async throws {
        let rig = try await ProfileSwitchTests.rig()
        defer { ProfileSwitchTests.tearDown(rig) }
        let store = rig.store
        store.start()
        try await ProfileSwitchTests.waitUntil { store.isRunning && ProfileSwitchTests.settled(store) }
        let controller = try #require(store.controller)
        var controlTimes: [Duration] = [], connectionTimes: [Duration] = []
        for index in 0..<12 {
            let node = rig.aNames[(index + 1) % 2]
            let host = "node-\(index).example.test"
            let began = ContinuousClock.now
            try await store.choose(node, in: "A-Select")
            let chosen = ContinuousClock.now
            controlTimes.append(chosen - began)
            let connection = try await Self.tunnel(to: host, port: store.proxyPort)
            defer { connection.cancel() }
            var reported: MihomoController.Connection?
            for _ in 0..<80 {
                reported = try await controller.connections().first { $0.metadata.host == host }
                if reported != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(reported?.chains.first == node)
            connectionTimes.append(.now - chosen)
        }
        for (label, times) in [("node choice", controlTimes), ("new connection chain", connectionTimes)] {
            let sorted = times.sorted()
            print("ROUTING-TIMING \(label) P50 \(ChangeTimeline.ms(sorted[5])), P95 \(ChangeTimeline.ms(sorted[11])) (12 trials, loopback)")
        }
    }

    @Test func aRouteMovesOnlyTheConnectionsItMatchesAndTheRestStayOpen() async throws {
        let rig = try await ProfileSwitchTests.rig()
        defer { ProfileSwitchTests.tearDown(rig) }
        let store = rig.store
        store.start()
        try await ProfileSwitchTests.waitUntil { store.isRunning && ProfileSwitchTests.settled(store) }
        let port = store.proxyPort
        let held = [try await Self.tunnel(to: "keep.test", port: port), try await Self.tunnel(to: "www.move.test", port: port),
                    try await Self.tunnel(to: "other.test", port: port)]
        defer { held.forEach { $0.cancel() } }
        let controller = try #require(store.controller)
        var hosts: Set<String> = []
        for _ in 0..<80 {
            hosts = Set(try await controller.connections().compactMap(\.metadata.host))
            if hosts.isSuperset(of: ["keep.test", "www.move.test", "other.test"]) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(hosts.isSuperset(of: ["keep.test", "www.move.test", "other.test"]))
        let set = try #require(store.hotSets?.set(for: "DIRECT"))
        let began = ContinuousClock.now
        try await store.coreConfigWork.run { _ = try await store.applyHotNow([(set, "DOMAIN-SUFFIX,move.test")], profile: rig.first.id) }
        let hot = ContinuousClock.now - began
        let after = Set(try await controller.connections().compactMap(\.metadata.host))
        #expect(after.contains("keep.test") && after.contains("other.test"))
        #expect(!after.contains("www.move.test"))
        print("ROUTING-TIMING hot route + targeted reconnect: \(ChangeTimeline.ms(hot))")

        // A reload with no route Veer can match closes nothing at all.
        let reloadBegan = ContinuousClock.now
        try await store.coreConfigWork.run { _ = try await store.reloadRunningCoreNow(profile: rig.first.id) }
        let reload = ContinuousClock.now - reloadBegan
        let afterReload = Set(try await controller.connections().compactMap(\.metadata.host))
        #expect(afterReload.isSuperset(of: ["keep.test", "other.test"]))
        print("ROUTING-TIMING full reload (PUT /configs), small profile: \(ChangeTimeline.ms(reload))")
    }
}
