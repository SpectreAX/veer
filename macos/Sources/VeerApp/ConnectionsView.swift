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
    @State private var selection = Set<ConnectionRow.ID>()
    @State private var addingRule: ConnectionRow?
    @State private var confirmingCloseAll = false

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
            .searchable(text: $query, placement: .toolbar, prompt: Text("搜索主机、进程、规则或节点"))
            .toolbar { toolbar }
            .onAppear { store.watchConnections(true) }
            .onDisappear { store.watchConnections(false) }
            .sheet(item: $addingRule) { AddRuleSheet(row: $0) }
            .confirmationDialog("关闭全部连接？", isPresented: $confirmingCloseAll) {
                Button("关闭全部", role: .destructive) { store.closeAllConnections() }
            } message: {
                Text("正在进行的下载和通话会中断，应用会按当前规则重新连接。")
            }
    }

    @ViewBuilder private var content: some View {
        if !store.isRunning {
            StateView(symbol: Page.connections.symbol, title: String(localized: "内核没有运行"),
                      message: String(localized: "启动后可以在这里实时查看连接。"),
                      actionTitle: store.activeProfile == nil ? nil : String(localized: "启动")) { store.start() }
        } else if store.connections.isEmpty {
            StateView(symbol: Page.connections.symbol, title: String(localized: "现在没有连接"),
                      message: String(localized: "开启系统代理，或让应用使用 127.0.0.1:\(String(store.proxyPort)) 作为代理后，连接会出现在这里。"))
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                table
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: Spacing.md) {
            Picker("进程", selection: $process) {
                Text("全部进程").tag(String?.none)
                ForEach(Set(store.connections.compactMap(\.process)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .fixedSize()
            Picker("策略组", selection: $policy) {
                Text("全部策略组").tag(String?.none)
                ForEach(Set(store.connections.map(\.policy)).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .fixedSize()
            Spacer()
            Text("\(shown.count) 个连接").font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("主机") { row in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(row.host).lineLimit(1).truncationMode(.middle).help(row.host)
                    if row.network == "udp" { Text(verbatim: "UDP").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("进程") { row in Text(row.process ?? "—").lineLimit(1).foregroundStyle(row.process == nil ? .secondary : .primary) }
                .width(min: 70, ideal: 110)
            TableColumn("规则") { row in Text(row.rule).lineLimit(1).help(row.rule) }
                .width(min: 90, ideal: 150)
            TableColumn("代理链") { row in Text(row.chain.joined(separator: " → ")).lineLimit(1).truncationMode(.middle).help(row.chain.joined(separator: " → ")) }
                .width(min: 140, ideal: 240)
            TableColumn("流量") { row in
                Text(verbatim: "↑\(Format.bytes(row.upload)) ↓\(Format.bytes(row.download))").font(Typography.codeSmall).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 140)
            TableColumn("速率") { row in
                Text(verbatim: Format.rate(row.downloadRate + row.uploadRate)).font(Typography.codeSmall)
                    .foregroundStyle(row.downloadRate + row.uploadRate > 0 ? .primary : .secondary)
            }
            .width(min: 70, ideal: 80)
            TableColumn("时长") { row in
                Text(verbatim: row.start.map { Format.duration(since: $0) } ?? "—").font(Typography.codeSmall).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)
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
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.connectionsPaused.toggle() } label: {
                store.connectionsPaused ? Label("继续刷新", systemImage: "play") : Label("暂停刷新", systemImage: "pause")
            }
            .help(store.connectionsPaused ? String(localized: "继续实时刷新") : String(localized: "暂停实时刷新，方便查看"))
            .disabled(!store.isRunning)
            Button { confirmingCloseAll = true } label: { Label("关闭全部连接", systemImage: "xmark.circle") }
                .help("关闭全部连接")
                .disabled(store.connections.isEmpty)
        }
    }

    private func rows(_ ids: Set<ConnectionRow.ID>) -> [ConnectionRow] { store.connections.filter { ids.contains($0.id) } }

    private func ask(_ text: String) {
        store.page = .agent
        agent.ask(text)
    }

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
                TextField("匹配内容", text: $value)
                Picker("出口", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                .disabled(targets.isEmpty)
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
