import AppKit
import SwiftUI
import VeerUI

/// SwiftUI Table remeasures hosted cells during every split-divider step. A native table keeps
/// cell layout in AppKit without a SwiftUI hosting view or constraints for each text cell.
struct ConnectionsTable: NSViewRepresentable {
    let rows: [ConnectionRow]
    /// For the requests page: the same rows as connections that have ended, in the same order.
    /// The table then shows when each ended in place of its speed, and offers no closing.
    var closed: [ClosedRequest]?
    @Binding var selection: Set<ConnectionRow.ID>
    var ask: (ConnectionRow) -> Void
    var addRule: (ConnectionRow) -> Void
    /// Nil where there is nothing left to close.
    var close: ((Set<ConnectionRow.ID>) -> Void)?

    /// How visible a column is whose far edge is at `columnEnd` in a viewport that ends at
    /// `viewportEnd`: whole while it is inside, gone once `fadeBand` of it is past the edge.
    ///
    /// The columns never change with the page's width: none is added, removed, resized or moved,
    /// so the header and the rows cannot part and nothing jumps when the Agent panel sets off or
    /// arrives. The page's edge passes over the far columns, and one that no longer fits whole
    /// fades instead of staying cut through its text. What is past the edge scrolls into view,
    /// and is in the selected connection's route below the table.
    static func trailingAlpha(columnEnd: CGFloat, viewportEnd: CGFloat) -> CGFloat {
        let past = columnEnd - viewportEnd
        return past <= fadeSlack ? 1 : max(0, 1 - (past - fadeSlack) / fadeBand)
    }

    static let fadeBand: CGFloat = 16
    /// A column that ends on the edge, give or take rounding, is inside.
    static let fadeSlack: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatchingViewport()
        coordinator.table.delegate = nil
        coordinator.table.dataSource = nil
        coordinator.table.menuForRow = nil
        coordinator.table.copyHosts = nil
        coordinator.table.closeSelection = nil
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = ConnectionTableView()
        private var parent: ConnectionsTable
        private var rows: [ConnectionRow] = []
        private var ended: [ClosedRequest] = []
        private var viewportObservers: [NSObjectProtocol] = []
        private var updating = false
        private var displayedSecond: TimeInterval = -1
        private let lineHeight = NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height
        private var contextIDs = Set<ConnectionRow.ID>()

        init(_ parent: ConnectionsTable) { self.parent = parent }

        func makeScrollView() -> NSScrollView {
            table.delegate = self
            table.dataSource = self
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.allowsColumnReordering = false
            table.usesAlternatingRowBackgroundColors = true
            // The host takes up or gives back the slack and every other column keeps its width and
            // place, so nothing in the table moves as the page narrows. Where the host is not the
            // first column, the ones around it are held at their widths so that it is still the
            // only one to give.
            let history = parent.closed != nil
            table.columnAutoresizingStyle = history ? .sequentialColumnAutoresizingStyle : .firstColumnOnlyAutoresizingStyle
            table.rowSizeStyle = .medium
            table.setAccessibilityLabel(history ? String(localized: "请求") : String(localized: "连接"))
            for spec in history ? ConnectionColumn.history : ConnectionColumn.live {
                let column = NSTableColumn(identifier: spec.identifier)
                let header = FadingHeaderCell(textCell: spec.title)
                header.font = column.headerCell.font
                header.alignment = column.headerCell.alignment
                header.lineBreakMode = column.headerCell.lineBreakMode
                column.headerCell = header
                // The time takes 8 points more than the speed it replaces, and the process gives them
                // up, so that the traffic still fits whole beside the Agent panel in the default window.
                let width = history && spec == .process ? spec.width - 8 : spec.width
                column.minWidth = history && spec != .host ? width : spec.minimum
                column.maxWidth = history && spec == .closed ? width : spec.maximum
                column.width = width
                table.addTableColumn(column)
            }
            table.menuForRow = { [weak self] in self?.menu(for: $0) }
            table.copyHosts = { [weak self] in self?.copy(self?.selectedIDs ?? []) }
            table.closeSelection = { [weak self] in
                guard let self else { return }
                parent.close?(selectedIDs)
            }
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            update(parent)
            watchViewport(of: scroll)
            return scroll
        }

        /// The viewport changes on every frame of the Agent panel's motion, when the window is
        /// resized and on a sideways scroll; each time the far columns are faded for where the
        /// edge is now. Nothing waits for the motion to end.
        private func watchViewport(of scroll: NSScrollView) {
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                viewportObservers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.table.fadeTrailingColumns() }
                })
            }
        }

        func stopWatchingViewport() {
            viewportObservers.forEach(NotificationCenter.default.removeObserver)
            viewportObservers = []
        }

        func tableViewColumnDidResize(_ notification: Notification) { table.fadeTrailingColumns() }

        func update(_ value: ConnectionsTable) {
            parent = value
            updating = true
            defer { updating = false }
            let changedRows = rows != value.rows
            let changedOrder = changedRows && (rows.count != value.rows.count || zip(rows, value.rows).contains { $0.0.id != $0.1.id })
            let metricsOnly = changedRows && !changedOrder && zip(rows, value.rows).allSatisfy { sameContent($0.0, $0.1) }
            let anchor = changedOrder ? scrollAnchor() : nil
            let second = Date.timeIntervalSinceReferenceDate.rounded(.down)
            let changedSecond = second != displayedSecond
            displayedSecond = second
            rows = value.rows
            ended = value.closed ?? []
            if metricsOnly {
                refreshPrepared(columns: changedSecond ? [.traffic, .speed, .duration] : [.traffic, .speed])
            } else if changedRows {
                table.reloadData()
                if let anchor, let index = rows.firstIndex(where: { $0.id == anchor.id }), let scroll = table.enclosingScrollView {
                    let top = table.rect(ofRow: index).minY + anchor.offset
                    let maximum = max(0, table.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(maximum, max(0, top))))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            let indexes = IndexSet(rows.indices.filter { value.selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            // Elapsed time can advance even when all byte counts stay unchanged; not once it has ended.
            if !changedRows, changedSecond, value.closed == nil { refreshPrepared(columns: [.duration]) }
        }

        /// Stable content and row heights let metric ticks refresh cells without rebuilding the table.
        private func sameContent(_ old: ConnectionRow, _ new: ConnectionRow) -> Bool {
            old.host == new.host && old.process == new.process && old.network == new.network
                && old.rule == new.rule && old.chain == new.chain && old.start == new.start
        }

        private func refreshPrepared(columns: [ConnectionColumn]) {
            // AppKit can retain rows beyond the viewport for responsive scrolling.
            let prepared = table.preparedContentRect
            let bounds = prepared.isEmpty ? table.visibleRect : prepared.union(table.visibleRect)
            let range = table.rows(in: bounds)
            guard range.location != NSNotFound, range.length > 0, range.location < rows.count else { return }
            // The cells that exist take their new text where they are. Asking the table to reload
            // them made every one again, once a second, and a refresh that landed while the Agent
            // panel moved cost a frame.
            for column in columns {
                let index = table.column(withIdentifier: column.identifier)
                guard index >= 0 else { continue }
                for row in range.location..<min(rows.count, NSMaxRange(range)) {
                    (table.view(atColumn: index, row: row, makeIfNecessary: false) as? ConnectionTableCell)?
                        .configure(rows[row], column: column, ended: ended.indices.contains(row) ? ended[row] : nil)
                }
            }
        }

        private func scrollAnchor() -> (id: String, offset: CGFloat)? {
            let top = table.visibleRect.minY
            let index = table.row(at: NSPoint(x: 0, y: top))
            guard rows.indices.contains(index) else { return nil }
            return (rows[index].id, top - table.rect(ofRow: index).minY)
        }

        var selectedIDs: Set<ConnectionRow.ID> {
            Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if !updating { parent.selection = selectedIDs }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return tableView.rowHeight }
            return rows[row].network == "udp" ? lineHeight * 2 + 6 : lineHeight + 6
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn,
                  let spec = ConnectionColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = (table.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ConnectionTableCell) ?? ConnectionTableCell(column: spec)
            cell.identifier = tableColumn.identifier
            cell.configure(rows[row], column: spec, ended: ended.indices.contains(row) ? ended[row] : nil)
            cell.alphaValue = table.alpha(of: tableColumn)
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].host : nil
        }

        func menu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            // Right-click within a multi-selection acts on it; outside it acts on the clicked row.
            contextIDs = table.selectedRowIndexes.contains(row) ? selectedIDs : [rows[row].id]
            let menu = NSMenu()
            menu.addItem(item(String(localized: "问 AI：为什么这样走？"), action: #selector(askAboutRoute)))
            menu.addItem(item(String(localized: "为这个主机添加规则…"), action: #selector(addHostRule)))
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "复制主机"), action: #selector(copyContextHosts)))
            if parent.close != nil {
                let title = contextIDs.count > 1 ? String(localized: "关闭 \(contextIDs.count) 个连接") : String(localized: "关闭连接")
                menu.addItem(item(title, action: #selector(closeContextConnections)))
            }
            return menu
        }

        private func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        private var contextRow: ConnectionRow? { rows.first { contextIDs.contains($0.id) } }
        @objc private func askAboutRoute() { if let row = contextRow { parent.ask(row) } }
        @objc private func addHostRule() { if let row = contextRow { parent.addRule(row) } }
        @objc private func copyContextHosts() { copy(contextIDs) }
        @objc private func closeContextConnections() { parent.close?(contextIDs) }

        private func copy(_ ids: Set<ConnectionRow.ID>) {
            let hosts = rows.filter { ids.contains($0.id) }.map(\.host)
            guard !hosts.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hosts.joined(separator: "\n"), forType: .string)
        }
    }
}

/// A column title that can be drawn part way to invisible (`ConnectionsTable.trailingAlpha`).
final class FadingHeaderCell: NSTableHeaderCell {
    var alpha: CGFloat = 1

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard alpha < 1, let context = NSGraphicsContext.current?.cgContext else { return super.draw(withFrame: cellFrame, in: controlView) }
        context.saveGState()
        context.setAlpha(alpha)
        super.draw(withFrame: cellFrame, in: controlView)
        context.restoreGState()
    }
}

final class ConnectionTableView: NSTableView {
    private var columnAlpha: [NSUserInterfaceItemIdentifier: CGFloat] = [:]

    func alpha(of column: NSTableColumn) -> CGFloat { columnAlpha[column.identifier] ?? 1 }

    /// Sets each column's title and cells to how much of it the viewport holds. Only what changed
    /// is touched, so a frame in which the edge is between columns costs a few comparisons.
    func fadeTrailingColumns() {
        let viewportEnd = visibleRect.maxX
        guard visibleRect.width > 0 else { return }
        for (index, column) in tableColumns.enumerated() {
            // The first column is the one thing always shown.
            let alpha = index == 0 ? 1 : ConnectionsTable.trailingAlpha(columnEnd: rect(ofColumn: index).maxX, viewportEnd: viewportEnd)
            guard alpha != self.alpha(of: column) else { continue }
            columnAlpha[column.identifier] = alpha
            if let header = column.headerCell as? FadingHeaderCell, let headerView {
                header.alpha = alpha
                headerView.setNeedsDisplay(headerView.headerRect(ofColumn: index))
            }
            enumerateAvailableRowViews { rowView, _ in (rowView.view(atColumn: index) as? NSView)?.alphaValue = alpha }
        }
    }

    var menuForRow: ((Int) -> NSMenu?)?
    var copyHosts: (() -> Void)?
    var closeSelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuForRow?(event.type == .keyDown ? selectedRow : row(at: convert(event.locationInWindow, from: nil)))
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard selectedRow >= 0, let menu = menuForRow?(selectedRow) else { return false }
        scrollRowToVisible(selectedRow)
        let rect = rect(ofRow: selectedRow).intersection(visibleRect)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.midX, y: rect.midY), in: self)
        return true
    }

    @objc func copy(_ sender: Any?) { if numberOfSelectedRows > 0 { copyHosts?() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return numberOfSelectedRows > 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift) {
            _ = accessibilityPerformShowMenu()
        } else if event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) {
            if numberOfSelectedRows > 0 { closeSelection?() }
        } else {
            super.keyDown(with: event)
        }
    }
}

private enum ConnectionColumn: String {
    /// Most wanted first: the page's trailing edge passes over the columns from the far end as the
    /// window or the Agent panel changes its width, and the rest scroll into view.
    case host, process, traffic, speed, duration, rule, chain
    /// When a connection ended, on the requests page.
    case closed

    static let live: [ConnectionColumn] = [.host, .process, .traffic, .speed, .duration, .rule, .chain]
    /// The time first, as in a log; the rule and the chain last, since the selected row's route shows them.
    static let history: [ConnectionColumn] = [.closed, .host, .process, .traffic, .duration, .rule, .chain]

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .host: String(localized: "主机")
        case .process: String(localized: "进程")
        case .rule: String(localized: "规则")
        case .chain: String(localized: "代理链")
        case .traffic: String(localized: "流量")
        case .speed: String(localized: "速率")
        case .duration: String(localized: "时长")
        case .closed: String(localized: "结束于")
        }
    }

    var width: CGFloat {
        switch self {
        case .host, .chain: 150
        case .process: 90
        case .rule: 100
        case .traffic: 105
        case .speed: 60
        case .duration: 64
        // "09:27:13" whole.
        case .closed: 72
        }
    }

    var minimum: CGFloat {
        switch self {
        // The host only ever gains the slack: squeezed, it is the first thing to stop being readable.
        case .host: 150
        case .traffic: 100
        case .process: 50
        case .rule: 60
        case .chain: 90
        case .speed: 56
        case .duration, .closed: 64
        }
    }

    var maximum: CGFloat {
        switch self {
        case .traffic: 140
        case .speed: 90
        case .duration: 72
        default: .greatestFiniteMagnitude
        }
    }
}

private final class ConnectionTableCell: NSTableCellView {
    private let value = NSTextField(labelWithString: "")
    private var udp: NSTextField?

    init(column: ConnectionColumn) {
        super.init(frame: .zero)
        textField = value
        addSubview(value)
        value.maximumNumberOfLines = 1
        let code = column == .traffic || column == .speed || column == .duration || column == .closed
        value.font = code ? .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        value.lineBreakMode = column == .host || column == .chain ? .byTruncatingMiddle : .byTruncatingTail
        value.setFrameSize(value.fittingSize)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        value.frame = NSRect(x: 3, y: 3, width: max(0, bounds.width - 6), height: value.frame.height)
        if let udp { udp.setFrameOrigin(NSPoint(x: 3, y: value.frame.maxY)) }
    }

    func configure(_ row: ConnectionRow, column: ConnectionColumn, ended: ClosedRequest? = nil) {
        let showsUDP = column == .host && row.network == "udp"
        if showsUDP, udp == nil {
            let label = NSTextField(labelWithString: "UDP")
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textColor = .secondaryLabelColor
            addSubview(label)
            label.setFrameSize(label.fittingSize)
            udp = label
        }
        udp?.isHidden = !showsUDP
        let content = ended.flatMap { Self.content(of: $0, column: column) } ?? Self.content(of: row, column: column)
        // Most refreshes change nothing in most cells; a tooltip is set again only with its text.
        if value.textColor != content.color { value.textColor = content.color }
        guard value.stringValue != content.text else { return }
        value.stringValue = content.text
        value.toolTip = content.tip ?? content.text
    }

    private struct Content {
        var text: String
        var color = NSColor.labelColor
        var tip: String?
    }

    /// What differs once a connection has ended: when it did, how long it had lasted, and that
    /// one seen only in the log has no traffic to show. Nil for the columns that read the same.
    private static func content(of request: ClosedRequest, column: ConnectionColumn) -> Content? {
        switch column {
        case .closed:
            Content(text: request.closedAt.formatted(date: .omitted, time: .standard), color: .secondaryLabelColor)
        case .traffic where request.fromLog:
            Content(text: "—", color: .secondaryLabelColor, tip: String(localized: "这个连接不到一秒就结束了，只在日志里有记录，没有流量数据。"))
        case .duration:
            Content(text: request.fromLog ? "< 1s" : request.row.start.map { Format.duration(since: $0, now: request.closedAt) } ?? "—",
                    color: .secondaryLabelColor)
        default: nil
        }
    }

    /// What a cell says and in which color.
    private static func content(of row: ConnectionRow, column: ConnectionColumn) -> Content {
        let secondary = NSColor.secondaryLabelColor
        switch column {
        case .host: return Content(text: row.host)
        case .process: return Content(text: row.process ?? "—", color: row.process == nil ? secondary : .labelColor)
        case .rule: return Content(text: row.rule)
        case .chain: return Content(text: row.chain.joined(separator: " → "))
        case .traffic: return Content(text: "↑\(Format.bytes(row.upload)) ↓\(Format.bytes(row.download))", color: secondary)
        case .speed:
            return Content(text: Format.rate(row.uploadRate + row.downloadRate), color: row.uploadRate + row.downloadRate == 0 ? secondary : .labelColor)
        case .duration: return Content(text: row.start.map { Format.duration(since: $0) } ?? "—", color: secondary)
        case .closed: return Content(text: "—", color: secondary)
        }
    }
}
