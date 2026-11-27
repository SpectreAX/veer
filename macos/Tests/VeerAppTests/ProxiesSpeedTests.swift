import Foundation
import Observation
import Testing
@testable import VeerApp
import VeerCore

/// Delays reach the one cell of each node that changed, a few times a second, and the groups only
/// when a run ends; the node menus are made from what is true when they open.
@MainActor struct ProxiesSpeedTests {
    typealias Member = ProxyStore.Group.Member
    /// Set when an observed property changes; the change can be reported from any thread.
    final class Flag: @unchecked Sendable { var value = false }

    static let tokyo = "🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路"

    /// Waits for the 150 ms flush, at most a second.
    func waitForFlush(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aResultReachesItsCellAtTheFlushAndLeavesTheGroupsAlone() async throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let cell = store.delayCell(for: Self.tokyo)
        #expect(cell.result == nil, "no result yet: each tile shows its member's own state")
        #expect(store.delayCell(for: Self.tokyo) === cell, "one cell per node, whichever group asks")

        let groups = store.groups, revision = store.delayRevision
        let groupsChanged = Flag()
        withObservationTracking { _ = store.groups } onChange: { groupsChanged.value = true }
        store.record(.measured(55), for: Self.tokyo, generation: store.generation)
        #expect(store.delays[Self.tokyo] == .measured(55))
        #expect(cell.result == nil, "not before the flush")
        await waitForFlush { cell.result == .measured(55) }
        #expect(cell.result == .measured(55))
        #expect(store.delayRevision > revision)
        #expect(store.groups == groups && !groupsChanged.value, "the groups are not rewritten while a test runs")

        // The run's end gives the groups the results, once.
        store.flushDelays(now: true)
        #expect(groupsChanged.value)
        #expect(store.groups.flatMap(\.members).filter { $0.name == Self.tokyo }.allSatisfy { $0.state == .measured(55) && $0.delay == 55 })
        // Nothing new: the groups are left as they are.
        let changedAgain = Flag()
        withObservationTracking { _ = store.groups } onChange: { changedAgain.value = true }
        store.flushDelays(now: true)
        #expect(!changedAgain.value)
    }

    @Test func resettingPutsCellsBackToWhatTheGroupsSay() async throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let cell = store.delayCell(for: Self.tokyo)
        store.record(.testing, for: Self.tokyo, generation: store.generation)
        await waitForFlush { cell.result == .testing }
        #expect(cell.result == .testing)
        let revision = store.delayRevision
        store.resetDelays()
        #expect(store.delays.isEmpty && store.pendingDelayNames.isEmpty)
        #expect(cell.result == nil)
        #expect(store.delayRevision > revision)
        // A result of the profile that was replaced does not land.
        store.record(.measured(1), for: Self.tokyo, generation: store.generation - 1)
        #expect(store.delays[Self.tokyo] == nil)
    }

    @Test func readingTheGroupsAgainUpdatesAndLetsGoOfCells() throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let osaka = "🇯🇵 日本 大阪 02"
        let tokyo = store.delayCell(for: Self.tokyo)
        store.setDelay(.measured(3), for: "Gone 01")
        let gone = store.delayCell(for: "Gone 01")
        let osakaCell = store.delayCell(for: osaka)
        store.setDelay(.measured(70), for: osaka)
        store.groups = [.init(name: "节点选择", type: "Selector", now: Self.tokyo, members: [
            Member(name: Self.tokyo, delay: 300, isGroup: false), Member(name: osaka, delay: 400, isGroup: false),
        ])]
        store.syncDelayCells()
        #expect(tokyo.result == nil, "no result of Veer's: the tile shows the core's history")
        #expect(osakaCell.result == .measured(70), "Veer's result")
        #expect(store.delayCells["Gone 01"] == nil && gone.result == .measured(3))
    }

    @Test func everythingIsTestedOnceNodesFirst() {
        let groups: [ProxyStore.Group] = [
            .init(name: "A", type: "Selector", now: nil, members: [Member(name: "B", delay: nil, isGroup: true), Member(name: "n1", delay: nil, isGroup: false),
                                                                    Member(name: "REJECT", delay: nil, isGroup: false)]),
            .init(name: "B", type: "URLTest", now: nil, members: [Member(name: "n1", delay: nil, isGroup: false),
                                                                   Member(name: "n2", delay: nil, isGroup: false)]),
        ]
        #expect(ProxyStore.everythingToTest(in: groups) == ["n1", "n2", "B"])
    }

    // MARK: Grid lines

    @Test func theGridIsOneListOfHeadersAndRows() {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        // 7, 3 and 2 members in 3 columns; the second group collapsed.
        let lines = GridLine.lines(store.groups, collapsed: ["自动选择"], columns: 3)
        func describe(_ line: GridLine) -> String {
            switch line.kind {
            case .header(let first): "\(line.group.name) header\(first ? " first" : "")"
            case .nodes(let members, let last): "\(line.group.name) \(members.count)\(last ? " last" : "")"
            }
        }
        #expect(lines.map(describe) == ["节点选择 header first", "节点选择 3", "节点选择 3", "节点选择 1 last", "自动选择 header", "Netflix header", "Netflix 2 last"])
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.first?.id == "节点选择", "a header is its group's name, which the page scrolls to")
        // The rows hold every member once, in order.
        let members = lines.compactMap { line -> [String]? in
            if case .nodes(let members, _) = line.kind, line.group.name == "节点选择" { return members.map(\.name) }
            return nil
        }.flatMap { $0 }
        #expect(members == store.groups[0].members.map(\.name))
        // A group with no members is its header alone, expanded or not.
        let empty = ProxyStore.Group(name: "空", type: "Selector", now: nil, members: [])
        #expect(GridLine.lines([empty], collapsed: [], columns: 3).count == 1)
    }

    // MARK: Node menus

    @Test func aSmallGroupIsListedFlat() throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let group = try #require(store.mainGroup)
        let menu = store.nodeMenu(group)
        #expect(menu.regions.isEmpty)
        #expect(menu.top.map(\.name) == group.members.map(\.name))
        #expect(menu.top.filter(\.selected).map(\.name) == [Self.tokyo])
        #expect(menu.top.first { $0.name == Self.tokyo }?.title == "\(Self.tokyo)    92 ms")
        #expect(menu.entries.count == group.members.count && !menu.entries.contains(.separator))
        #expect(menu.entries.first { $0.checked }?.kind == .item(id: Self.tokyo))
    }

    @Test func aBigGroupFoldsIntoRegionsWithTheLatestDelays() throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        func nodes(_ prefix: String, _ count: Int, delay: Int?) -> [Member] {
            (0..<count).map { Member(name: "\(prefix) \(String(format: "%02d", $0))", delay: delay, isGroup: false) }
        }
        let members = [Member(name: "自动选择", delay: 80, isGroup: true), Member(name: "DIRECT", delay: nil, isGroup: false)]
            + nodes("Tokyo", 6, delay: 100) + nodes("Premium", 3, delay: nil) + nodes("HK", 4, delay: 50)
            + nodes("SG", 3, delay: 0) + nodes("USA", 3, delay: 300)
        let group = ProxyStore.Group(name: "节点选择", type: "Selector", now: "SG 01", members: members)
        store.delays["HK 02"] = .measured(9)

        let menu = store.nodeMenu(group)
        #expect(menu.top.map(\.name) == ["自动选择", "DIRECT"])
        // Most nodes first; a tie by code; nodes in no known region last.
        #expect(menu.regions.map(\.code) == ["JP", "HK", "SG", "US", nil])
        #expect(menu.regions.map(\.items.count) == [6, 4, 3, 3, 3])
        let hk = try #require(menu.regions.first { $0.code == "HK" })
        #expect(hk.title.hasSuffix("· 4 · 9 ms"), "the latest result, before any flush: \(hk.title)")
        #expect(hk.items.first { $0.name == "HK 02" }?.title == "HK 02    9 ms")
        let singapore = try #require(menu.regions.first { $0.code == "SG" })
        #expect(singapore.containsSelected && singapore.items.filter(\.selected).map(\.name) == ["SG 01"])
        #expect(menu.regions.filter(\.containsSelected).count == 1)
        #expect(menu.regions.last?.title.hasPrefix(String(localized: "其他")) == true)

        let entries = menu.entries
        #expect(entries.count == 2 + 1 + 5)
        #expect(entries[2] == .separator)
        guard case .submenu(let children) = entries[5].kind else { Issue.record("not a submenu"); return }
        #expect(entries[5].checked && children.count == 3 && children.contains { $0.checked && $0.kind == .item(id: "SG 01") })
    }

    // MARK: Map

    @Test func theMapsRegionsStandStillWhileResultsComeIn() throws {
        let store = SnapshotRunner.running(page: .proxies)
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let before = NodeMapView.regions(in: store, matching: "")
        store.record(.measured(5), for: "🇯🇵 日本 大阪 02", generation: store.generation)
        #expect(NodeMapView.regions(in: store, matching: "") == before)
        let japan = try #require(before["JP"])
        #expect(MapNode.bestDelay(in: japan) == 92)
        #expect(MapNode.bestDelay(in: japan, latest: store.delays) == 5)
        #expect(NodeMapView.regionSummary("JP", nodes: japan, latest: store.delays).contains("5 ms"))
        // Search still finds by name and by region.
        #expect(NodeMapView.regions(in: store, matching: "大阪")["JP"]?.map(\.name) == ["🇯🇵 日本 大阪 02"])
        #expect(NodeMapView.regions(in: store, matching: "香港").keys.map { $0 } == ["HK"])
    }
}
