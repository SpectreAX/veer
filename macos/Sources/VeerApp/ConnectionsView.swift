import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// Live connections: where each goes, which rule sent it there, and how fast.
struct ConnectionsView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @State private var query = ""
    @State private var process: String?
    @State private var policy: String?
    @State private var selection: Set<ConnectionRow.ID>
    @State private var columns = TableColumnCustomization<ConnectionRow>()
    @State private var hiddenColumns = Set<String>()
    @State private var measuredWidth: CGFloat = 0

    private static let columnWidths: [ColumnFit.Column] = [
        .init("host", ideal: 150), .init("process", ideal: 90), .init("rule", ideal: 100), .init("chain", ideal: 150),
        .init("traffic", ideal: 105), .init("speed", ideal: 60), .init("duration", ideal: 64),
    ]
    /// The selected row's route shows the first two, and the host always stays.
    private static let columnsGivenUp = ["rule", "chain", "duration", "process", "speed"]
    @State private var addingRule: ConnectionRow?

    init(selection: Set<ConnectionRow.ID> = []) {
        _selection = State(initialValue: selection)
    }

    private var shown: [ConnectionRow] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.connections.filter { row in
            (process == nil || row.process == process) && (policy == nil || row.policy == policy)
                && (text.isEmpty || row.host.lowercased().contains(text) || (row.process?.lowercased().contains(text) ?? false)
                    || row.rule.lowercased().contains(text) || row.chain.contains { $0.lowercased().contains(text) })
        }
    }

    var body: some View {
        content
            .pageToolbar(.connections) { toolbar } content: {
                ToolbarSearchField(text: $query, prompt: Text("搜索连接"), help: String(localized: "搜索主机、进程、规则或节点"))
            }
            .onAppear { store.watchConnections(true) }
            .onDisappear { store.watchConnections(false) }
            .sheet(item: $addingRule) { AddRuleSheet(row: $0) }
            .confirmationDialog("关闭全部连接？", isPresented: Binding(get: { store.confirmingCloseAllConnections },
                                                               set: { store.confirmingCloseAllConnections = $0 })) {
                Button("关闭全部", role: .destructive) { store.closeAllConnections() }
            } message: {
                Text("正在进行的下载和通话会中断，应用会按当前规则重新连接。")
            }
    }

    @ViewBuilder private var content: some View {
        if !store.isRunning {
            CoreNotRunningView(symbol: Page.connections.symbol, message: String(localized: "启动后可以在这里实时查看连接。"))
        } else if store.connections.isEmpty {
            StateView(symbol: Page.connections.symbol, title: String(localized: "现在没有连接"),
                      message: String(localized: "开启系统代理，或让应用使用 127.0.0.1:\(String(store.proxyPort)) 作为代理后，连接会出现在这里。"))
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                table
                // One selected connection: its route, rule to node. Below, so that it leaves the columns alone.
                if selection.count == 1, let row = shown.first(where: { selection.contains($0.id) }) {
                    Divider()
                    RouteMap(row: row) {
                        RouteActions(row: row, addRule: { addingRule = row }, close: { store.closeConnection(row.id) })
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            // Once it settles: the first layout measures next to nothing, and the Agent panel passes
            // through every width as it opens. Columns hidden on the way come back squeezed.
            .task(id: measuredWidth) {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { fitColumns(to: measuredWidth) }
            }
        }
    }

    /// With labels and the count while they fit; beside the Agent panel in a small window, the pickers alone.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.md) {
                filterPickers
                Spacer()
                Text("\(shown.count) 个连接").font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
            }
            HStack(spacing: Spacing.sm) {
                filterPickers.labelsHidden()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder private var filterPickers: some View {
        Picker("进程", selection: $process) {
            Text("全部进程").tag(String?.none)
            ForEach(Set(store.connections.compactMap(\.process)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
        }
        .fixedSize()
        .neutralControl()
        Picker("策略组", selection: $policy) {
            Text("全部策略组").tag(String?.none)
            ForEach(Set(store.connections.map(\.policy)).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
        }
        .fixedSize()
        .neutralControl()
    }

    private var table: some View {
        Table(shown, selection: $selection, columnCustomization: $columns) {
            TableColumn("主机") { row in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(row.host).lineLimit(1).truncationMode(.middle).help(row.host)
                    if row.network == "udp" { Text(verbatim: "UDP").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .width(min: 100, ideal: 150)
            .customizationID("host").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("进程") { row in
                Text(row.process ?? "—").lineLimit(1).foregroundStyle(row.process == nil ? .secondary : .primary)
                    .help(row.process ?? "")
            }
                .width(min: 50, ideal: 90)
                .customizationID("process").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("规则") { row in Text(row.rule).lineLimit(1).help(row.rule) }
                .width(min: 60, ideal: 100)
                .customizationID("rule").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("代理链") { row in Text(row.chain.joined(separator: " → ")).lineLimit(1).truncationMode(.middle).help(row.chain.joined(separator: " → ")) }
                .width(min: 90, ideal: 150)
                .customizationID("chain").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("流量") { row in
                Text(verbatim: "↑\(Format.bytes(row.upload)) ↓\(Format.bytes(row.download))").font(Typography.codeSmall).foregroundStyle(.secondary)
                    .help(Text(verbatim: "↑\(Format.bytes(row.upload)) ↓\(Format.bytes(row.download))"))
            }
            .width(min: 100, ideal: 105, max: 140)
            .customizationID("traffic").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("速率") { row in
                Text(verbatim: Format.rate(row.downloadRate + row.uploadRate)).font(Typography.codeSmall)
                    .foregroundStyle(row.downloadRate + row.uploadRate > 0 ? .primary : .secondary)
            }
            .width(min: 56, ideal: 60, max: 90)
            .customizationID("speed").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("时长") { row in
                Text(verbatim: row.start.map { Format.duration(since: $0) } ?? "—").font(Typography.codeSmall).foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 64, max: 72)
            .customizationID("duration").disabledCustomizationBehavior([.reorder, .visibility])
        }
        .contextMenu(forSelectionType: ConnectionRow.ID.self) { ids in
            if let row = rows(ids).first {
                Button("问 AI：为什么这样走？") { ask(String(localized: "为什么 \(row.host) 走了“\(row.policy)”？")) }
                Button("为这个主机添加规则…") { addingRule = row }
                Divider()
                Button("复制主机") { copy(rows(ids).map(\.host).joined(separator: "\n")) }
                Button(ids.count > 1 ? String(localized: "关闭 \(ids.count) 个连接") : String(localized: "关闭连接")) {
                    for id in ids { store.closeConnection(id) }
                }
            }
        }
        .onDeleteCommand { for id in selection { store.closeConnection(id) } }
        // Nil with nothing selected, which leaves the clipboard and the menu item alone.
        .onCopyCommand(perform: selection.isEmpty ? nil : {
            [NSItemProvider(object: rows(selection).map(\.host).joined(separator: "\n") as NSString)]
        })
        // A new table when the columns change, the one way to get clean widths: an existing one squeezes
        // or stretches them whatever it is told. The window or the Agent panel can do that, a selection
        // can't, so this doesn't take the focus from someone choosing a row.
        .id(hiddenColumns)
    }

    /// Hides what no longer fits as the table narrows. Only on a change: writing this resets the widths.
    private func fitColumns(to width: CGFloat) {
        let hidden = ColumnFit.hidden(in: width, columns: Self.columnWidths, givingUp: Self.columnsGivenUp)
        guard hidden != hiddenColumns else { return }
        hiddenColumns = hidden
        // From scratch: this also holds the widths the old table had. A width someone dragged goes with them.
        var fresh = TableColumnCustomization<ConnectionRow>()
        for id in hidden { fresh[visibility: id] = .hidden }
        columns = fresh
    }

    @ViewBuilder private var toolbar: some View {
        Button { store.connectionsPaused.toggle() } label: {
            store.connectionsPaused ? Label("继续刷新", systemImage: "play") : Label("暂停刷新", systemImage: "pause")
        }
        .help(store.connectionsPaused ? String(localized: "继续实时刷新") : String(localized: "暂停实时刷新，方便查看"))
        .disabled(!store.isRunning)
        Button { store.confirmingCloseAllConnections = true } label: { Label("关闭全部连接", systemImage: "xmark.circle") }
            .help("关闭全部连接")
            .disabled(store.connections.isEmpty)
    }

    private func rows(_ ids: Set<ConnectionRow.ID>) -> [ConnectionRow] { store.connections.filter { ids.contains($0.id) } }

    private func ask(_ text: String) { agent.open(asking: text) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A rule for one host, recorded in "my routing" like any other change.
struct AddRuleSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let row: ConnectionRow
    @State private var matchType = "DOMAIN-SUFFIX"
    @State private var value = ""
    @State private var target = ""
    @State private var targets: [String] = []
    @State private var adding = false
    @State private var error: String?

    private var types: [String] { row.isAddress ? ["IP-CIDR"] : ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD"] }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("为这个主机添加规则").font(.title3.weight(.semibold))
                Text("新规则放在最前面，记在“我的分流”里，订阅更新后仍然有效，也可以随时撤销。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Picker("匹配方式", selection: $matchType) {
                    ForEach(types, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                }
                .neutralControl()
                TextField("匹配内容", text: $value)
                Picker("出口", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                .disabled(targets.isEmpty)
                .neutralControl()
            }
            .formStyle(.grouped)
            if let error { StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if adding { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction(.regular)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || target.isEmpty || adding)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .onAppear {
            matchType = types[0]
            value = row.address.map { $0.isV4 ? "\($0)/32" : "\($0)/128" } ?? row.host
        }
        .task {
            targets = await store.ruleTargets()
            target = targets.contains(row.policy) ? row.policy : (targets.first ?? "")
        }
    }

    private func add() {
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                try await store.addRule(matchType: matchType == "IP-CIDR" && value.contains(":") ? "IP-CIDR6" : matchType,
                                        value: value.trimmingCharacters(in: .whitespaces), target: target)
                dismiss()
            } catch {
                self.error = store.message(for: error)
            }
        }
    }

    static func title(of type: String) -> String {
        switch type {
        case "DOMAIN-SUFFIX": String(localized: "域名及子域名")
        case "DOMAIN": String(localized: "完整域名")
        case "DOMAIN-KEYWORD": String(localized: "包含关键词")
        default: String(localized: "IP 地址")
        }
    }
}

/// How one connection was routed, top to bottom: the host, the rule that matched it, each
/// group it passed through and the node it left by.
private let routeMapMaxHeight: CGFloat = 220

struct RouteMap<Actions: View>: View {
    let row: ConnectionRow
    @ViewBuilder var actions: () -> Actions
    @State private var height = routeMapMaxHeight

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let label: String
        let value: String
    }

    private var steps: [Step] {
        var steps = [Step(id: 0, symbol: "globe", label: String(localized: "主机"),
                          value: row.process.map { "\(row.host)\n\($0)" } ?? row.host),
                     Step(id: 1, symbol: "line.3.horizontal.decrease", label: String(localized: "规则"), value: row.rule)]
        for (index, hop) in row.chain.enumerated() {
            let last = index == row.chain.count - 1
            steps.append(Step(id: index + 2, symbol: last ? "point.topleft.down.to.point.bottomright.curvepath" : "square.stack.3d.up",
                              label: last ? String(localized: "出口") : String(localized: "策略组"), value: hop))
        }
        return steps
    }

    var body: some View {
        // Its own height while that is short enough, so that it takes no more from the table than it needs.
        ScrollView {
            panel.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(height, routeMapMaxHeight))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.md) { flow(arrow: "arrow.right") }
                VStack(alignment: .leading, spacing: Spacing.xs) { flow(arrow: "arrow.down") }
            }
            .accessibilityElement(children: .combine)
            actions()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func flow(arrow: String) -> some View {
        ForEach(steps) { step in
            if step.id > 0 {
                Image(systemName: arrow).font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: step.symbol).foregroundStyle(Color.veerAccent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(step.label).font(.caption).foregroundStyle(.secondary)
                    Text(step.value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension RouteMap where Actions == EmptyView {
    init(row: ConnectionRow) {
        self.init(row: row) { EmptyView() }
    }
}

/// What the right-click menu offers for one connection or request, in view for the selected row.
struct RouteActions: View {
    @Environment(AgentStore.self) private var agent
    let row: ConnectionRow
    let addRule: () -> Void
    /// Only for one still open.
    var close: (() -> Void)?

    var body: some View {
        // In a row while they fit, else one above the other at full width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.sm) { buttons }
            VStack(spacing: Spacing.sm) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        action(String(localized: "问 AI：为什么这样走？")) { agent.open(asking: String(localized: "为什么 \(row.host) 走了“\(row.policy)”？")) }
        action(String(localized: "为这个主机添加规则…"), perform: addRule)
        action(String(localized: "复制主机")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.host, forType: .string)
        }
        if let close { action(String(localized: "关闭连接"), perform: close) }
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
        }
        .secondaryAction()
    }
}
