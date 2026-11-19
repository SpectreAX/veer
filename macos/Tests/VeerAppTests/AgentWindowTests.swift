import Foundation
import Testing
@testable import VeerApp
import VeerCore
import VeerProxy

/// The Agent hidden, docked as the panel, or in a window of its own: one store whichever it is, so a
/// move re-sends, re-requests and re-applies nothing.
@MainActor @Suite(.serialized) struct AgentWindowTests {
    // MARK: Presentation

    @Test func aVersionFromBeforeTheWindowKeepsItsPanel() {
        #expect(AgentPresentation.saved(nil, panel: nil) == .docked)
        #expect(AgentPresentation.saved(nil, panel: true) == .docked)
        #expect(AgentPresentation.saved(nil, panel: false) == .hidden)
        #expect(AgentPresentation.saved("detached", panel: false) == .detached)
        #expect(AgentPresentation.saved("nonsense", panel: false) == .hidden)
        #expect(AgentPresentation.savedLast(nil, current: .hidden) == .docked)
        #expect(AgentPresentation.savedLast("detached", current: .hidden) == .detached)
        #expect(AgentPresentation.savedLast("hidden", current: .hidden) == .docked)
        #expect(AgentPresentation.savedLast("docked", current: .detached) == .detached)
    }

    @Test func theToolbarButtonBringsAWindowForwardAndOtherwiseTheLastPlace() {
        #expect(AgentPresentation.detached.toggled(last: .detached) == .detached)
        #expect(AgentPresentation.docked.toggled(last: .docked) == .hidden)
        #expect(AgentPresentation.hidden.toggled(last: .docked) == .docked)
        #expect(AgentPresentation.hidden.toggled(last: .detached) == .detached)
    }

    @Test func detachingClosingAndDockingFollowTheLifecycle() throws {
        let made = try stores()
        let proxy = made.proxy, agent = made.agent, opened = made.opened
        proxy.agentPresentation = .docked
        agent.detach()
        #expect(proxy.agentPresentation == .detached)
        #expect(!proxy.agentPanel)
        #expect(opened.agent == 1)
        // Detaching again, or the toolbar's button, brings the one window forward.
        agent.detach()
        agent.toggleFromToolbar()
        #expect(opened.agent == 3)
        #expect(proxy.agentPresentation == .detached)
        // Closing the panel's way does not close the window.
        proxy.agentPanel = false
        #expect(proxy.agentPresentation == .detached)
        // Closing the window hides the Agent; the panel does not open.
        agent.windowClosed()
        #expect(proxy.agentPresentation == .hidden)
        #expect(proxy.lastAgentPresentation == .detached)
        // The toolbar's button and ⌘N then bring the window back.
        agent.toggleFromToolbar()
        #expect(proxy.agentPresentation == .detached)
        #expect(opened.agent == 4)
        agent.windowClosed()
        agent.showAgent()
        #expect(proxy.agentPresentation == .detached)
        #expect(opened.agent == 5)
        // Docking opens the main window if it was closed, and the panel.
        agent.dock()
        #expect(opened.main == 1)
        #expect(proxy.agentPresentation == .docked)
        #expect(proxy.lastAgentPresentation == .docked)
        agent.toggleFromToolbar()
        #expect(proxy.agentPresentation == .hidden)
        agent.toggleFromToolbar()
        #expect(proxy.agentPresentation == .docked)
        #expect(opened.agent == 5)
    }

    @Test func aWindowOpenedFromTheWindowMenuIsWhereTheAgentIs() throws {
        let made = try stores()
        let proxy = made.proxy, agent = made.agent
        proxy.agentPresentation = .docked
        agent.windowAppeared()
        #expect(proxy.agentPresentation == .detached)
    }

    @Test func thePlaceIsSavedForTheNextLaunch() throws {
        let suite = "veer-agent-window-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let paths = VeerPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let first = ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in "" }), binary: nil, defaults: defaults)
        first.agentPresentation = .detached
        first.agentPresentation = .hidden
        #expect(defaults.bool(forKey: "agentPanel") == false)
        let second = ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in "" }), binary: nil, defaults: defaults)
        #expect(second.agentPresentation == .hidden)
        #expect(second.lastAgentPresentation == .detached)
    }

    @Test func showingTheAgentOnItsOwnPageOpensNoPanel() throws {
        let made = try stores()
        let proxy = made.proxy, agent = made.agent, opened = made.opened
        proxy.agentPresentation = .hidden
        proxy.lastAgentPresentation = .docked
        proxy.page = .agent
        agent.showAgent()
        #expect(proxy.agentPresentation == .hidden)
        #expect(opened.agent == 0)
        proxy.page = .overview
        agent.showAgent()
        #expect(proxy.agentPresentation == .docked)
    }

    // MARK: Scroll position

    @Test func theScrollSpotGoesOnceToTheSameConversationJustAfterAMove() throws {
        let agent = try stores().agent
        let session = UUID(), turn = UUID()
        agent.scrollSpot = ScrollSpot(session: session, followsBottom: false, topTurnID: turn)
        agent.detach()
        let taken = try #require(agent.takeScrollHandoff(for: session))
        #expect(!taken.followsBottom)
        #expect(taken.topTurnID == turn)
        #expect(agent.takeScrollHandoff(for: session) == nil)
        // Another conversation, or one opened long after, opens at its newest turn.
        agent.dock()
        #expect(agent.takeScrollHandoff(for: UUID()) == nil)
        agent.handOffScroll()
        #expect(agent.takeScrollHandoff(for: session, now: .now.addingTimeInterval(ScrollSpot.handoffLifetime + 1)) == nil)
    }

    // MARK: Switching while a turn streams (mock AI)

    @Test func movingWhileATurnStreamsSendsItOnceAndKeepsEverything() async throws {
        let transport = GatedTransport()
        let made = try stores(engine: EditorEngine(ai: AIClient(transport: transport)))
        let proxy = made.proxy, agent = made.agent, opened = made.opened
        agent.settings.provider = .ollama
        agent.settings.thinkingLevel = .high
        agent.useAI = true
        agent.searchSettings.enabled = false
        agent.executionMode = .manual
        proxy.agentPresentation = .docked
        agent.send("Netflix 走日本")
        let sessionID = try #require(agent.current?.id)
        try await waitUntil("request sent") { await transport.requests == 1 }
        #expect(agent.isRunning)
        // What is being written next, and the composer's settings.
        agent.composerText = "YouTube 走香港"
        let attachment = ChatAttachment(info: AttachmentInfo(name: "rules.txt", kind: .text), text: "a,b")
        agent.pendingAttachments = [attachment]

        agent.detach()
        #expect(agent.isRunning)
        agent.windowClosed()
        #expect(agent.isRunning)
        agent.toggleFromToolbar()
        agent.dock()
        agent.detach()
        #expect(opened.agent == 3)
        #expect(proxy.agentPresentation == .detached)
        #expect(agent.isRunning)
        #expect(agent.current?.id == sessionID)
        #expect(agent.current?.turns.count == 1)
        #expect(agent.composerText == "YouTube 走香港")
        #expect(agent.pendingAttachments.map(\.id) == [attachment.id])
        #expect(agent.settings.provider == .ollama && agent.settings.thinkingLevel == .high)
        #expect(!agent.searchSettings.enabled)
        #expect(agent.executionMode == .manual)

        await transport.release()
        try await waitUntil("turn ended") { !agent.isRunning }
        #expect(await transport.requests == 1)
        #expect(agent.current?.turns.count == 1)
        #expect(agent.composerText == "YouTube 走香港")
        #expect(!proxy.systemProxyOn)
    }

    // MARK: Placement (AppKit coordinates)

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func theFirstWindowOpensBesideTheMainWindowOnItsScreen() throws {
        let main = CGRect(x: 100, y: 100, width: 800, height: 720)
        let frame = try #require(AgentWindowPlacement.frame(saved: nil, screens: [screen, second], anchor: main))
        #expect(frame.size == AgentWindowPlacement.defaultSize)
        #expect(frame.minX == main.maxX + AgentWindowPlacement.gap)
        #expect(frame.maxY == main.maxY)
        #expect(screen.contains(frame))
    }

    @Test func withNoRoomBesideItTheWindowOpensOverTheMainWindowsTrailingEdge() throws {
        let main = CGRect(x: 2000, y: 200, width: 1200, height: 800)
        let frame = try #require(AgentWindowPlacement.frame(saved: nil, screens: [screen, second], anchor: main))
        #expect(second.contains(frame))
        #expect(frame.maxX == main.maxX - AgentWindowPlacement.gap)
        #expect(frame.size == AgentWindowPlacement.defaultSize)
    }

    @Test func aSavedFrameOnADisconnectedDisplayComesBackOnScreen() throws {
        let saved = CGRect(x: 2400, y: 200, width: 600, height: 800)
        #expect(AgentWindowPlacement.frame(saved: saved, screens: [screen, second], anchor: nil) == saved)
        let main = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frame = try #require(AgentWindowPlacement.frame(saved: saved, screens: [screen], anchor: main))
        #expect(screen.contains(frame))
        #expect(frame.size == saved.size)
    }

    @Test func aFrameIsKeptWhollyOnItsScreenAndNoSmallerThanTheMinimum() {
        let half = AgentWindowPlacement.clamp(CGRect(x: 1200, y: -100, width: 520, height: 1200), into: screen)
        #expect(screen.contains(half))
        #expect(half.height == screen.height)
        let tiny = AgentWindowPlacement.clamp(CGRect(x: 10, y: 10, width: 100, height: 100), into: screen)
        #expect(tiny.size == AgentWindowPlacement.minimumSize)
        let small = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(AgentWindowPlacement.clamp(CGRect(x: 0, y: 0, width: 520, height: 720), into: small) == small)
        #expect(AgentWindowPlacement.frame(saved: nil, screens: [], anchor: nil) == nil)
    }

    // MARK: Helpers

    final class Opened {
        var agent = 0
        var main = 0
    }

    struct Stores {
        let proxy: ProxyStore
        let agent: AgentStore
        let opened: Opened
    }

    private func stores(engine: EditorEngine? = nil) throws -> Stores {
        let proxy = SnapshotRunner.sample()
        let defaults = try #require(UserDefaults(suiteName: "veer-agent-window-\(UUID().uuidString)"))
        let agent = AgentStore(proxy: proxy, engine: engine, defaults: defaults, persist: false)
        let opened = Opened()
        proxy.openAgentWindow = { opened.agent += 1 }
        proxy.openMainWindow = { opened.main += 1 }
        return Stores(proxy: proxy, agent: agent, opened: opened)
    }

    private func waitUntil(_ stage: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EditorError("Timed out: \(stage)")
    }
}

/// An AI service that starts answering, then holds the rest until released, as a slow stream does.
private actor GatedTransport: AITransport {
    private(set) var requests = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    private static let answer = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"clarification\":\"哪个地区？\"}"}}]}"#

    func release() {
        released = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    private func gate() async {
        requests += 1
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate()
        return (Data(Self.answer.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        await gate()
        let chunk = #"data: {"choices":[{"delta":{"content":"{\"clarification\":\"哪个地区？\"}"},"finish_reason":"stop"}]}"#
        let lines = [chunk, "", "data: [DONE]", ""]
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}
