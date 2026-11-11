import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// Connections that have closed, newest first: where short requests went, after they are gone
/// from the connections page. Kept in memory only, at most a thousand.
struct RequestsView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @State private var query = ""
    @State private var selection: Set<ClosedRequest.ID>
    @State private var columns = TableColumnCustomization<ClosedRequest>()
    @State private var hiddenColumns = Set<String>()
    @State private var measuredWidth: CGFloat = 0
    @Environment(\.pageTargetWidth) private var targetWidth

    private static let columnWidths: [ColumnFit.Column] = [
        .init("closed", ideal: 64), .init("host", ideal: 150), .init("process", ideal: 90), .init("rule", ideal: 100),
        .init("chain", ideal: 150), .init("traffic", ideal: 105), .init("duration", ideal: 64),
    ]
    /// The selected row's route shows the first two, and the host and when it ended always stay.
    private static let columnsGivenUp = ["rule", "chain", "process", "duration", "traffic"]
    @State private var addingRule: ConnectionRow?

    init(selection: Set<ClosedRequest.ID> = []) {
        _selection = State(initialValue: selection)
    }

    private var shown: [ClosedRequest] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return store.requests }
        return store.requests.filter { request in
            let row = request.row
            return row.host.lowercased().contains(text) || (row.process?.lowercased().contains(text) ?? false)
                || row.rule.lowercased().contains(text) || row.chain.contains { $0.lowercased().contains(text) }
        }
    }

    var body: some View {
        content
            .pageToolbar(.requests) {
                Button { agent.clearRequests() } label: { Label("清空", systemImage: "trash") }
                    .help("清空请求记录")
                    .disabled(store.requests.isEmpty)
            } content: {
                ToolbarSearchField(text: $query, prompt: Text("搜索请求"), help: String(localized: "搜索主机、进程、规则或节点"))
            }
            .sheet(item: $addingRule) { AddRuleSheet(row: $0) }
    }

    @ViewBuilder private var content: some View {
        if store.requests.isEmpty, !store.isRunning {
            CoreNotRunningView(symbol: Page.requests.symbol,
                               message: String(localized: "连接结束后会出现在这里，最多保留 1000 条，退出 Veer 后清空。不到一秒的连接从日志里补上，需要日志级别为 info 或 debug。"))
        } else if store.requests.isEmpty {
            StateView(symbol: Page.requests.symbol, title: String(localized: "还没有结束的连接"),
                      message: String(localized: "连接结束后会出现在这里，最多保留 1000 条，退出 Veer 后清空。不到一秒的连接从日志里补上，需要日志级别为 info 或 debug。"))
        } else {
            VStack(spacing: 0) {
                table
                // One selected request: where it went, as on the connections page.
                if selection.count == 1, let row = shown.first(where: { selection.contains($0.id) })?.row {
                    Divider()
                    RouteMap(row: row) {
                        RouteActions(row: row, addRule: { addingRule = row })
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            // Once it settles: the first layout measures next to nothing, and the Agent panel passes
            // through every width as it opens. Columns hidden on the way come back squeezed.
            .task(id: measuredWidth) {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { fitColumns(to: targetWidth ?? measuredWidth) }
            }
            // As on the Connections page: the columns for where the page is going, as it sets off.
            .onChange(of: store.agentPanel) { if let targetWidth { fitColumns(to: targetWidth) } }
        }
    }

    /// Hides what no longer fits as the table narrows. Only on a change: writing this resets the widths.
    private func fitColumns(to width: CGFloat) {
        let hidden = ColumnFit.hidden(in: width, columns: Self.columnWidths, givingUp: Self.columnsGivenUp)
        guard hidden != hiddenColumns else { return }
        hiddenColumns = hidden
        // From scratch: this also holds the widths the old table had. A width someone dragged goes with them.
        var fresh = TableColumnCustomization<ClosedRequest>()
        for id in hidden { fresh[visibility: id] = .hidden }
        columns = fresh
    }

    private var table: some View {
        Table(shown, selection: $selection, columnCustomization: $columns) {
            TableColumn("结束于") { request in
                Text(request.closedAt.formatted(date: .omitted, time: .standard)).font(Typography.codeSmall).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 64, max: 76)
            .customizationID("closed").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("主机") { request in Text(request.row.host).lineLimit(1).truncationMode(.middle).help(request.row.host) }
                .width(min: 100, ideal: 150)
                .customizationID("host").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("进程") { request in
                Text(request.row.process ?? "—").lineLimit(1).foregroundStyle(request.row.process == nil ? .secondary : .primary)
                    .help(request.row.process ?? "")
            }
            .width(min: 50, ideal: 90)
            .customizationID("process").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("规则") { request in Text(request.row.rule).lineLimit(1).help(request.row.rule) }
                .width(min: 60, ideal: 100)
                .customizationID("rule").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("代理链") { request in
                Text(request.row.chain.joined(separator: " → ")).lineLimit(1).truncationMode(.middle).help(request.row.chain.joined(separator: " → "))
            }
            .width(min: 90, ideal: 150)
            .customizationID("chain").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("流量") { request in
                Text(verbatim: request.fromLog ? "—" : "↑\(Format.bytes(request.row.upload)) ↓\(Format.bytes(request.row.download))")
                    .font(Typography.codeSmall).foregroundStyle(.secondary)
                    .help(request.fromLog ? String(localized: "这个连接不到一秒就结束了，只在日志里有记录，没有流量数据。") : "")
            }
            .width(min: 100, ideal: 105, max: 140)
            .customizationID("traffic").disabledCustomizationBehavior([.reorder, .visibility])
            TableColumn("时长") { request in
                Text(verbatim: request.fromLog ? "< 1s" : request.row.start.map { Format.duration(since: $0, now: request.closedAt) } ?? "—")
                    .font(Typography.codeSmall).foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 64, max: 72)
            .customizationID("duration").disabledCustomizationBehavior([.reorder, .visibility])
        }
        .contextMenu(forSelectionType: ClosedRequest.ID.self) { ids in
            if let request = store.requests.first(where: { ids.contains($0.id) }) {
                Button("问 AI：为什么这样走？") {
                    agent.open(asking: String(localized: "为什么 \(request.row.host) 走了“\(request.row.policy)”？"))
                }
                Button("为这个主机添加规则…") { addingRule = request.row }
                Divider()
                Button("复制主机") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.requests.filter { ids.contains($0.id) }.map(\.row.host).joined(separator: "\n"), forType: .string)
                }
            }
        }
        .onCopyCommand(perform: selection.isEmpty ? nil : {
            [NSItemProvider(object: store.requests.filter { selection.contains($0.id) }.map(\.row.host).joined(separator: "\n") as NSString)]
        })
        // A new table when the columns change, the one way to get clean widths: an existing one squeezes
        // or stretches them whatever it is told. The window or the Agent panel can do that, a selection
        // can't, so this doesn't take the focus from someone choosing a row.
        .id(hiddenColumns)
    }
}

/// Asks the core's own DNS, the way its rules and nodes resolve names. The core keeps no
/// history of queries, so there is none here either.
struct DNSView: View {
    @Environment(ProxyStore.self) private var store
    @State private var name = ""
    @State private var type = "A"
    @State private var result: MihomoController.DNSResult?
    @State private var elapsed: Duration?
    @State private var error: String?
    @State private var asking = false

    static let types = ["A", "AAAA", "CNAME", "HTTPS", "TXT", "MX"]
    private static let domainFieldWidth: CGFloat = 220

    private var domainField: some View {
        TextField("域名", text: $name, prompt: Text(verbatim: "www.example.com"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(ask)
    }

    @ViewBuilder private var lookupControls: some View {
        Picker("类型", selection: $type) { ForEach(Self.types, id: \.self) { Text(verbatim: $0).tag($0) } }
            .labelsHidden().fixedSize().neutralControl()
        Button("查询", action: ask).primaryAction(.regular).keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || asking)
    }

    var body: some View {
        if !store.isRunning {
            CoreNotRunningView(symbol: Page.dns.symbol, message: String(localized: "启动后可以用内核的 DNS 查询域名。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // The field on a line of its own when it would be too short to read a domain in.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.sm) {
                            domainField.frame(minWidth: Self.domainFieldWidth)
                            lookupControls
                        }
                        VStack(alignment: .trailing, spacing: Spacing.sm) {
                            domainField
                            HStack(spacing: Spacing.sm) { lookupControls }
                        }
                    }
                    Text("用内核的 DNS 设置解析，结果和规则、节点看到的一致。fake-ip 模式下会得到 198.18 开头的虚拟地址。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error { StatusBadge(kind: .failure, text: error) }
                    if let result { answers(result) }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func answers(_ result: MihomoController.DNSResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(result.status == 0 ? String(localized: "\(result.answers.count) 条记录") : String(localized: "没有结果（状态 \(result.status)）"))
                    .font(.headline)
                Spacer()
                if let elapsed {
                    Text(verbatim: "\(Int(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000)) ms")
                        .font(Typography.codeSmall).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(result.answers.enumerated()), id: \.offset) { _, answer in
                HStack(spacing: Spacing.md) {
                    Text(verbatim: answer.typeName).font(Typography.codeSmall).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                    Text(verbatim: answer.data).font(Typography.code).textSelection(.enabled)
                    Spacer()
                    Text(verbatim: "TTL \(answer.ttl)").font(Typography.codeSmall).foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
                Divider()
            }
        }
        .panel()
    }

    private func ask() {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !asking else { return }
        asking = true
        error = nil
        Task {
            defer { asking = false }
            let clock = ContinuousClock(), started = clock.now
            do {
                result = try await store.lookUp(query, type: type)
                elapsed = clock.now - started
            } catch {
                result = nil
                self.error = store.message(for: error)
            }
        }
    }
}
