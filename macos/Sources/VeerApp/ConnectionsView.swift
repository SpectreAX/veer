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
            // Filtered once for the count, the table and the route below it.
            let shown = shown
            VStack(spacing: 0) {
                filterBar(count: shown.count)
                Divider()
                table(shown)
                // One selected connection: its route, rule to node, which the far columns also show.
                if selection.count == 1, let row = shown.first(where: { selection.contains($0.id) }) {
                    Divider()
                    RouteMap(row: row) {
                        RouteActions(row: row, addRule: { addingRule = row }, close: { store.closeConnection(row.id) })
                    }
                }
            }
        }
    }

    /// The pickers keep their place at the leading edge whatever the width, each naming what it
    /// filters in its own title ("全部进程"), so nothing in the bar changes form as the Agent panel
    /// moves. The count follows the trailing edge, and gives way only when it would meet them.
    private func filterBar(count: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            filterPickers
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                Text("\(count) 个连接").font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                Color.clear.frame(width: 0, height: 0)
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
        .labelsHidden()
        .fixedSize()
        .neutralControl()
        .help("按进程筛选")
        Picker("策略组", selection: $policy) {
            Text("全部策略组").tag(String?.none)
            ForEach(Set(store.connections.map(\.policy)).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
        }
        .labelsHidden()
        .fixedSize()
        .neutralControl()
        .help("按策略组筛选")
    }

    private func table(_ rows: [ConnectionRow]) -> some View {
        ConnectionsTable(rows: rows, selection: $selection,
                         ask: { row in ask(String(localized: "为什么 \(row.host) 走了“\(row.policy)”？")) },
                         addRule: { addingRule = $0 },
                         close: { ids in for id in ids { store.closeConnection(id) } })
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

    private func ask(_ text: String) { agent.open(asking: text) }
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
                    ForEach(targets.uniqued(), id: \.self) { Text($0).tag($0) }
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
