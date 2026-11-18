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
            ConnectionsTable(rows: rows, selection: binding, ask: { _ in }, addRule: { _ in }, close: { _ in })
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
        let view = ConnectionsTable(rows: rows, selection: .constant(Set(rows.prefix(2).map(\.id))),
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

    @Test func shrinkingRowsDoesNotLeaveStaleRowAccess() {
        let rows = metricRows(upload: 0)
        #expect(Set(rows.map(\.id)).count == 600)
        let view = ConnectionsTable(rows: rows, selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(ConnectionsTable(rows: [], selection: .constant([]),
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
        let view = ConnectionsTable(rows: rows, selection: .constant([rows[100].id]),
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
        coordinator.update(ConnectionsTable(rows: updated, selection: view.$selection,
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
        var view = ConnectionsTable(rows: rows, selection: .constant([rows[0].id]),
                                    ask: { _ in }, addRule: { _ in }, close: { closed = $0 })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = coordinator.table
        let process = try #require(table.tableColumns.dropFirst().first)
        process.width = 200
        view = ConnectionsTable(rows: Array(rows.dropLast()), selection: view.$selection,
                                ask: { _ in }, addRule: { _ in }, close: { closed = $0 })
        coordinator.update(view)
        // No update takes a column away or puts a dragged width back.
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        #expect(process.width == 200)
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
        let view = ConnectionsTable(rows: SnapshotRunner.sampleConnections(), selection: .constant([]),
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

    @Test func liveMetricUpdatesPreserveTheViewportAndReachOffscreenCells() throws {
        let rows = metricRows(upload: 0)
        let view = ConnectionsTable(rows: rows, selection: .constant([rows[100].id]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        scroll.layoutSubtreeIfNeeded()
        let table = coordinator.table
        table.scrollRowToVisible(100)
        let origin = scroll.contentView.bounds.origin
        let row = table.row(at: NSPoint(x: 0, y: table.visibleRect.minY))
        try #require(row >= 0)
        let column = table.column(withIdentifier: .init("traffic"))
        let before = try #require((table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
        let updated = metricRows(upload: 100_000)
        coordinator.update(ConnectionsTable(rows: updated, selection: view.$selection,
                                             ask: { _ in }, addRule: { _ in }, close: { _ in }))
        let after = try #require((table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
        #expect(after != before)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(coordinator.selectedIDs == [rows[100].id])
        table.scrollRowToVisible(500)
        let offscreen = try #require((table.view(atColumn: column, row: 500, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
        #expect(offscreen == after)
        withExtendedLifetime(scroll) {}
    }

    @Test func changedRowContentStillRefreshesNativeCells() throws {
        let original = metricRows(upload: 0)
        let view = ConnectionsTable(rows: original, selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        scroll.layoutSubtreeIfNeeded()
        let table = coordinator.table
        let column = table.column(withIdentifier: .init("host"))
        let oldHeight = coordinator.tableView(table, heightOfRow: 0)
        coordinator.update(ConnectionsTable(rows: metricRows(upload: 0, firstHost: "changed.example", firstNetwork: "udp"),
                                             selection: .constant([]),
                                             ask: { _ in }, addRule: { _ in }, close: { _ in }))
        let cell = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.stringValue == "changed.example")
        #expect(coordinator.tableView(table, heightOfRow: 0) > oldHeight)
        withExtendedLifetime(scroll) {}
    }

    @Test func preloadedRowsOutsideTheViewportReceiveCurrentMetrics() throws {
        let view = ConnectionsTable(rows: metricRows(upload: 0), selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        scroll.layoutSubtreeIfNeeded()
        let table = coordinator.table
        table.scrollRowToVisible(80)
        let range = table.rows(in: table.visibleRect)
        let cachedRow = NSMaxRange(range) + 1
        try #require(cachedRow < table.numberOfRows)
        let cachedRect = table.rect(ofRow: cachedRow)
        #expect(!table.visibleRect.intersects(cachedRect))
        table.prepareContent(in: table.visibleRect.union(cachedRect))
        table.preparedContentRect = table.visibleRect.union(cachedRect)
        let column = table.column(withIdentifier: .init("traffic"))
        let before = try #require((table.view(atColumn: column, row: cachedRow, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
        coordinator.update(ConnectionsTable(rows: metricRows(upload: 200_000), selection: .constant([]),
                                             ask: { _ in }, addRule: { _ in }, close: { _ in }))
        let prepared = try #require((table.view(atColumn: column, row: cachedRow, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue)
        #expect(prepared != before)
        table.scrollRowToVisible(cachedRow)
        let visible = try #require((table.view(atColumn: column, row: cachedRow, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
        #expect(visible == prepared)
        withExtendedLifetime(scroll) {}
    }

    private func metricRows(upload: Int64, firstHost: String = "host-0.example", firstNetwork: String = "tcp") -> [ConnectionRow] {
        (0..<600).map { index in
            ConnectionRow(MihomoController.Connection(id: "metric-\(index)",
                                                       metadata: .init(network: index == 0 ? firstNetwork : "tcp",
                                                                       host: index == 0 ? firstHost : "host-\(index).example"),
                                                       chains: [], rule: "Match", rulePayload: "", upload: upload, download: 0, start: nil),
                          uploadRate: upload, downloadRate: 0)
        }
    }

    @Test func aColumnFadesAsThePageEdgePassesItsEnd() {
        // Inside, or ending on the edge.
        #expect(ConnectionsTable.trailingAlpha(columnEnd: 300, viewportEnd: 400) == 1)
        #expect(ConnectionsTable.trailingAlpha(columnEnd: 400.5, viewportEnd: 400) == 1)
        // Part way past: part way gone, more with every point.
        let near = ConnectionsTable.trailingAlpha(columnEnd: 405, viewportEnd: 400)
        let far = ConnectionsTable.trailingAlpha(columnEnd: 412, viewportEnd: 400)
        #expect(near < 1 && far < near && far > 0)
        // Cut through: not drawn.
        #expect(ConnectionsTable.trailingAlpha(columnEnd: 400 + ConnectionsTable.fadeSlack + ConnectionsTable.fadeBand, viewportEnd: 400) == 0)
        #expect(ConnectionsTable.trailingAlpha(columnEnd: 900, viewportEnd: 400) == 0)
    }

    @Test func theSameColumnsStayAtEveryWidthAndOnlyThoseThatFitWholeAreDrawn() throws {
        let view = ConnectionsTable(rows: SnapshotRunner.sampleConnections(), selection: .constant([]),
                                    ask: { _ in }, addRule: { _ in }, close: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = coordinator.table
        func drawn() -> [String] {
            table.fadeTrailingColumns()
            return table.tableColumns.filter { table.alpha(of: $0) == 1 }.map(\.identifier.rawValue)
        }
        func place(width: CGFloat) -> [CGFloat] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            scroll.layoutSubtreeIfNeeded()
            return table.tableColumns.indices.map { table.rect(ofColumn: $0).minX }
        }
        let wide = place(width: 900)
        #expect(drawn().count == 7)
        // Beside the Agent panel: every column where it was (the host has given back its slack),
        // the far ones not drawn, none hidden, and the header fading with its cells.
        let narrow = place(width: 484)
        #expect(drawn() == ["host", "process", "traffic", "speed"])
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        let shift = wide[1] - narrow[1]
        #expect(zip(wide, narrow).dropFirst().allSatisfy { abs(($0 - $1) - shift) < 0.5 })
        let chain = try #require(table.tableColumns.last)
        #expect((chain.headerCell as? FadingHeaderCell)?.alpha == 0)
        let cell = try #require(coordinator.tableView(table, viewFor: chain, row: 0))
        #expect(cell.alphaValue == 0)
        // Scrolled sideways to the end, the far columns are the ones in view.
        scroll.contentView.scroll(to: NSPoint(x: table.frame.width - scroll.contentView.bounds.width, y: 0))
        #expect(drawn().contains("chain"))
        // Wide again: all back, with nothing rebuilt.
        _ = place(width: 900)
        #expect(drawn().count == 7 && (chain.headerCell as? FadingHeaderCell)?.alpha == 1)
        withExtendedLifetime(scroll) {}
    }

    @Test func endedRequestsShowWhenEachEndedAndOfferNoClosing() throws {
        let rows = SnapshotRunner.sampleConnections()
        let ended = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let requests = rows.enumerated().map { ClosedRequest(row: $1, closedAt: ended, fromLog: $0 == 1) }
        let view = ConnectionsTable(rows: rows, closed: requests, selection: .constant([rows[0].id]), ask: { _ in }, addRule: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = coordinator.table
        // The time first, no speed, and the two the route shows last.
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["closed", "host", "process", "traffic", "duration", "rule", "chain"])
        func text(_ column: String, row: Int) -> String? {
            let found = table.tableColumns.first { $0.identifier.rawValue == column }
            return (coordinator.tableView(table, viewFor: found, row: row) as? NSTableCellView)?.textField?.stringValue
        }
        #expect(text("closed", row: 0) == ended.formatted(date: .omitted, time: .standard))
        // Its length is what it was when it ended, not counted on from then.
        let start = try #require(rows[0].start)
        #expect(text("duration", row: 0) == Format.duration(since: start, now: ended))
        // Seen only in the log: under a second, and no traffic to show.
        #expect(text("duration", row: 1) == "< 1s" && text("traffic", row: 1) == "—")
        #expect(text("host", row: 1) == rows[1].host)
        // Nothing to close: not in the menu, and Delete does nothing.
        let menu = try #require(coordinator.menu(for: 0))
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == 3)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "\u{7f}",
                                                  charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        table.keyDown(with: event)
        // Beside the Agent panel the same columns stay, and the far ones are not drawn.
        scroll.frame = NSRect(x: 0, y: 0, width: 484, height: 300)
        scroll.layoutSubtreeIfNeeded()
        table.fadeTrailingColumns()
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        #expect(table.tableColumns.filter { table.alpha(of: $0) == 1 }.map(\.identifier.rawValue) == ["closed", "host", "process", "traffic"])
        withExtendedLifetime(scroll) {}
    }
}
