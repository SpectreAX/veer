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
            let shown = shown
            VStack(spacing: 0) {
                table(shown)
                // One selected request: where it went, as on the connections page.
                if selection.count == 1, let row = shown.first(where: { selection.contains($0.id) })?.row {
                    Divider()
                    RouteMap(row: row) {
                        RouteActions(row: row, addRule: { addingRule = row })
                    }
                }
            }
        }
    }

    /// The connections page's table, with when each request ended in place of its speed: the same
    /// columns at every width, the far ones fading as the page's edge passes them, so nothing is
    /// rebuilt or moved when the Agent panel opens or closes.
    private func table(_ shown: [ClosedRequest]) -> some View {
        ConnectionsTable(rows: shown.map(\.row), closed: shown, selection: $selection,
                         ask: { row in agent.open(asking: String(localized: "为什么 \(row.host) 走了“\(row.policy)”？")) },
                         addRule: { addingRule = $0 },
                         testRoute: { store.testRoute($0) })
    }
}
