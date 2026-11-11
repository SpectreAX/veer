import AppKit
import SwiftUI
import Testing
@testable import VeerApp
import VeerCore

@Suite(.serialized) @MainActor struct ConnectionsTableTests {
    @Test func selectionFollowsIDsThroughUpdatesAndFiltering() throws {
        let rows = SnapshotRunner.sampleConnections()
        let first = try #require(rows.first)
        var selection: Set<String> = [first.id]
        let binding = Binding(get: { selection }, set: { selection = $0 })
        func view(_ rows: [ConnectionRow]) -> ConnectionsTable {
            ConnectionsTable(rows: rows, hiddenColumns: [], selection: binding, ask: { _ in }, addRule: { _ in }, close: { _ in })
        }
        let coordinator = view(rows).makeCoordinator()
        let scroll = coordinator.makeScrollView()
        #expect(coordinator.selectedIDs == [first.id])
        coordinator.update(view(Array(rows.reversed())))
        #expect(coordinator.selectedIDs == [first.id])
        coordinator.update(view(Array(rows.dropFirst())))
        #expect(coordinator.selectedIDs.isEmpty)
        #expect(selection == [first.id])
        coordinator.update(view(rows))
        #expect(coordinator.selectedIDs == [first.id])
        coordinator.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(selection == [rows[1].id])
        withExtendedLifetime(scroll) {}
    }

    @Test func contextActionsUseClickedRowOrExistingMultiSelection() throws {
        let rows = SnapshotRunner.sampleConnections()
        var closed: Set<String> = []
        var asked: String?
        var adding: String?
        let view = ConnectionsTable(rows: rows, hiddenColumns: [], selection: .constant(Set(rows.prefix(2).map(\.id))),
                                    ask: { asked = $0.id }, addRule: { adding = $0.id }, close: { closed = $0 })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let selected = try #require(coordinator.menu(for: 1))
        selected.performActionForItem(at: 4)
        #expect(closed == Set(rows.prefix(2).map(\.id)))
        let clicked = try #require(coordinator.menu(for: 2))
        clicked.performActionForItem(at: 0)
        clicked.performActionForItem(at: 1)
        clicked.performActionForItem(at: 4)
        #expect(asked == rows[2].id)
        #expect(adding == rows[2].id)
        #expect(closed == [rows[2].id])
        #expect(coordinator.menu(for: -1) == nil)
        withExtendedLifetime(scroll) {}
    }

    @Test func shrinkingRowsWhileChangingColumnsDoesNotLeaveStaleRowAccess() {
        let rows = (0..<100).flatMap { _ in SnapshotRunner.sampleConnections() }
        let view = ConnectionsTable(rows: rows, hiddenColumns: [], selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(ConnectionsTable(rows: [], hiddenColumns: ["rule", "chain"], selection: .constant([]),
                                             ask: { _ in }, addRule: { _ in }, close: { _ in }))
        #expect(coordinator.table.numberOfRows == 0)
        #expect(coordinator.tableView(coordinator.table, viewFor: coordinator.table.tableColumns.first, row: 599) == nil)
        #expect(coordinator.tableView(coordinator.table, typeSelectStringFor: nil, row: 599) == nil)
        #expect(coordinator.tableView(coordinator.table, heightOfRow: 599) == coordinator.table.rowHeight)
        withExtendedLifetime(scroll) {}
    }

    @Test func refreshedRowsKeepTheVisibleIDAndUDPCellsRemainDistinct() throws {
        func row(_ index: Int) -> ConnectionRow {
            ConnectionRow(MihomoController.Connection(id: "r\(index)", metadata: .init(network: index == 0 ? "udp" : "tcp", host: "host-\(index)"),
                                                       chains: [], rule: "Match", rulePayload: "", upload: 0, download: 0, start: nil),
                          uploadRate: 0, downloadRate: 0)
        }
        let rows = (0..<600).map(row)
        let view = ConnectionsTable(rows: rows, hiddenColumns: [], selection: .constant([rows[100].id]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        scroll.layoutSubtreeIfNeeded()
        coordinator.table.scrollRowToVisible(200)
        let table = coordinator.table
        let before = table.row(at: NSPoint(x: 0, y: table.visibleRect.minY))
        #expect(before > 0)
        let topID = rows[before].id
        let offset = table.visibleRect.minY - table.rect(ofRow: before).minY
        let updated = [row(-1)] + Array(rows.dropFirst(4))
        coordinator.update(ConnectionsTable(rows: updated, hiddenColumns: [], selection: view.$selection,
                                             ask: { _ in }, addRule: { _ in }, close: { _ in }))
        let after = table.row(at: NSPoint(x: 0, y: table.visibleRect.minY))
        #expect(updated[after].id == topID)
        #expect(abs(table.visibleRect.minY - table.rect(ofRow: after).minY - offset) < 1)
        #expect(coordinator.selectedIDs == [rows[100].id])
        coordinator.update(view)
        #expect(coordinator.tableView(table, heightOfRow: 0) > coordinator.tableView(table, heightOfRow: 1))
        let cell = try #require(coordinator.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let labels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("UDP"))
        withExtendedLifetime(scroll) {}
    }

    @Test func columnsAndKeyboardActionsRetainNativeBehavior() throws {
        let rows = SnapshotRunner.sampleConnections()
        var closed: Set<String> = []
        var view = ConnectionsTable(rows: rows, hiddenColumns: ["rule", "chain"], selection: .constant([rows[0].id]),
                                    ask: { _ in }, addRule: { _ in }, close: { closed = $0 })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = coordinator.table
        #expect(table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue).sorted() == ["chain", "rule"])
        let host = try #require(table.tableColumns.first)
        host.width = 200
        coordinator.update(view)
        #expect(host.width == 200)
        view = ConnectionsTable(rows: rows, hiddenColumns: [], selection: view.$selection,
                                ask: { _ in }, addRule: { _ in }, close: { closed = $0 })
        coordinator.update(view)
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        // AppKit also redistributes spare width; the manually dragged width must be discarded.
        #expect(host.width != 200)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "\u{7f}",
                                                  charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        table.keyDown(with: event)
        #expect(closed == [rows[0].id])
        closed = []
        table.deselectAll(nil)
        table.keyDown(with: event)
        #expect(closed.isEmpty)
        withExtendedLifetime(scroll) {}
    }

    @Test func columnsKeepTheirPlaceAndOnlyTheHostTakesTheSlack() {
        let view = ConnectionsTable(rows: SnapshotRunner.sampleConnections(), hiddenColumns: [], selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = coordinator.table
        // Most wanted first, so the page's edge covers the least wanted.
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["host", "process", "traffic", "speed", "duration", "rule", "chain"])
        #expect(table.columnAutoresizingStyle == .firstColumnOnlyAutoresizingStyle)
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        scroll.layoutSubtreeIfNeeded()
        let wide = table.tableColumns.map(\.width)
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        scroll.layoutSubtreeIfNeeded()
        let narrow = table.tableColumns.map(\.width)
        // Narrower than its columns, it scrolls: none is hidden and none but the host changes width.
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        #expect(Array(wide.dropFirst()) == Array(narrow.dropFirst()))
        #expect(narrow[0] >= 150)
        #expect(table.frame.width > 420)
        withExtendedLifetime(scroll) {}
    }
}
