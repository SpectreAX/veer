import AppKit
import SwiftUI

/// SwiftUI Table remeasures hosted cells during every split-divider step. A native table keeps
/// cell layout in AppKit without a SwiftUI hosting view or constraints for each text cell.
struct ConnectionsTable: NSViewRepresentable {
    let rows: [ConnectionRow]
    let hiddenColumns: Set<String>
    @Binding var selection: Set<ConnectionRow.ID>
    var ask: (ConnectionRow) -> Void
    var addRule: (ConnectionRow) -> Void
    var close: (Set<ConnectionRow.ID>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
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
        private var hiddenColumns: Set<String>?
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
            // place, so nothing in the table moves as the page narrows: its edge just covers them.
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            table.rowSizeStyle = .medium
            table.setAccessibilityLabel(String(localized: "连接"))
            for spec in ConnectionColumn.allCases {
                let column = NSTableColumn(identifier: spec.identifier)
                column.title = spec.title
                column.minWidth = spec.minimum
                column.maxWidth = spec.maximum
                column.width = spec.width
                table.addTableColumn(column)
            }
            table.menuForRow = { [weak self] in self?.menu(for: $0) }
            table.copyHosts = { [weak self] in self?.copy(self?.selectedIDs ?? []) }
            table.closeSelection = { [weak self] in
                guard let self else { return }
                parent.close(selectedIDs)
            }
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            update(parent)
            return scroll
        }

        func update(_ value: ConnectionsTable) {
            parent = value
            updating = true
            defer { updating = false }
            let changedRows = rows != value.rows
            let changedOrder = rows.map(\.id) != value.rows.map(\.id)
            let anchor = changedOrder ? scrollAnchor() : nil
            let second = Date.timeIntervalSinceReferenceDate.rounded(.down)
            let changedSecond = second != displayedSecond
            displayedSecond = second
            rows = value.rows
            if hiddenColumns != value.hiddenColumns {
                hiddenColumns = value.hiddenColumns
                for column in table.tableColumns {
                    guard let spec = ConnectionColumn(rawValue: column.identifier.rawValue) else { continue }
                    column.isHidden = value.hiddenColumns.contains(spec.rawValue)
                    column.width = spec.width
                }
            }
            if changedRows {
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
            // Traffic can be unchanged while the elapsed time advances. Refresh only visible cells.
            if !changedRows, changedSecond, !rows.isEmpty {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound, visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                     columnIndexes: IndexSet(integer: table.column(withIdentifier: ConnectionColumn.duration.identifier)))
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
            cell.configure(rows[row], column: spec)
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
            let title = contextIDs.count > 1 ? String(localized: "关闭 \(contextIDs.count) 个连接") : String(localized: "关闭连接")
            menu.addItem(item(title, action: #selector(closeContextConnections)))
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
        @objc private func closeContextConnections() { parent.close(contextIDs) }

        private func copy(_ ids: Set<ConnectionRow.ID>) {
            let hosts = rows.filter { ids.contains($0.id) }.map(\.host)
            guard !hosts.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hosts.joined(separator: "\n"), forType: .string)
        }
    }
}

final class ConnectionTableView: NSTableView {
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

private enum ConnectionColumn: String, CaseIterable {
    /// Most wanted first: the page's trailing edge covers and uncovers the columns from the far end
    /// as the window or the Agent panel changes its width, and the rest scroll into view.
    case host, process, traffic, speed, duration, rule, chain
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
        case .duration: 64
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
        let code = column == .traffic || column == .speed || column == .duration
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

    func configure(_ row: ConnectionRow, column: ConnectionColumn) {
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
        value.textColor = .labelColor
        switch column {
        case .host: value.stringValue = row.host
        case .process:
            value.stringValue = row.process ?? "—"
            if row.process == nil { value.textColor = .secondaryLabelColor }
        case .rule: value.stringValue = row.rule
        case .chain: value.stringValue = row.chain.joined(separator: " → ")
        case .traffic:
            value.stringValue = "↑\(Format.bytes(row.upload)) ↓\(Format.bytes(row.download))"
            value.textColor = .secondaryLabelColor
        case .speed:
            value.stringValue = Format.rate(row.uploadRate + row.downloadRate)
            if row.uploadRate + row.downloadRate == 0 { value.textColor = .secondaryLabelColor }
        case .duration:
            value.stringValue = row.start.map { Format.duration(since: $0) } ?? "—"
            value.textColor = .secondaryLabelColor
        }
        value.toolTip = value.stringValue
    }
}
