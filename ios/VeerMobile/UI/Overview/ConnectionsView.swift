import SwiftUI

struct ConnectionsView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var search = ""
    @State private var pausedAt: Date?
    @State private var confirmingClose = false

    private var filtered: [ConnectionRow] {
        guard !search.isEmpty else { return store.connections }
        return store.connections.filter {
            [$0.host, $0.rule, $0.chain.joined(separator: " → ")].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if !store.isRunning {
                ContentUnavailableView("内核没有运行", systemImage: "arrow.left.arrow.right", description: Text("启动后可以在这里实时查看连接。"))
            } else {
                List {
                    Section {
                        if filtered.isEmpty {
                            // The prototype note is the empty state's description, centred with
                            // its title (design review 2, item 3).
                            ContentUnavailableView {
                                Label("现在没有连接", systemImage: "arrow.left.arrow.right")
                            } description: {
                                Text(prototypeNote)
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(filtered) { row in
                            connection(row)
                                .swipeActions(edge: .trailing) {
                                    Button("关闭", role: .destructive) { store.closeConnection(row.id) }
                                        .accessibilityLabel("关闭连接")
                                        .accessibilityIdentifier("connection-close-\(row.id)")
                                }
                        }
                    } footer: {
                        if !filtered.isEmpty { Text(prototypeNote) }
                    }
                    if let notice = store.notice {
                        StatusBadge(kind: .failure, text: notice, font: .footnote)
                            .accessibilityIdentifier("connections-error")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: Text("搜索连接"))
        .accessibilityIdentifier("connections-list")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.connectionsPaused.toggle()
                    pausedAt = store.connectionsPaused ? .now : nil
                } label: { Image(systemName: store.connectionsPaused ? "play.fill" : "pause.fill") }
                    .tint(.primary) // toolbar glyphs stay .primary (design review 1, item 7)
                    .accessibilityLabel(store.connectionsPaused ? String(localized: "继续刷新连接") : String(localized: "暂停刷新连接"))
                    .accessibilityIdentifier("connections-pause")
                    .disabled(!store.isRunning)
                Button("关闭全部", systemImage: "xmark.circle") { confirmingClose = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("connections-close-all")
                    .disabled(!store.isRunning || store.connections.isEmpty)
            }
        }
        .alert("关闭全部连接？", isPresented: $confirmingClose) {
            Button("关闭全部", role: .destructive) { store.closeAllConnections() }
                .accessibilityIdentifier("connections-confirm-close-all")
            Button("取消", role: .cancel) {}
        }
        .onAppear { store.watchConnections(true) }
        .onDisappear { store.watchConnections(false); store.connectionsPaused = false }
        .sensoryFeedback(.selection, trigger: store.connectionsPaused)
    }

    private var prototypeNote: String {
        String(localized: "原型版不接管 iPhone 的网络，这里只显示经过 Veer 内核的连接，例如检测出口 IP。")
    }

    private func connection(_ row: ConnectionRow) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s)) : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.m))
        return layout {
            connectionIdentity(row)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            connectionMetrics(row)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-\(row.id)")
    }
    private func connectionIdentity(_ row: ConnectionRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(row.host).font(.body).lineLimit(1).truncationMode(.middle)
            Text([row.rule, row.chain.joined(separator: " → ")].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func connectionMetrics(_ row: ConnectionRow) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            Text("↓ \(OverviewFormat.bytes(row.download))")
            if let start = row.start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(OverviewFormat.duration(start, now: pausedAt ?? context.date))
                }
            }
        }
        .font(.codeSmall).monospacedDigit().foregroundStyle(.secondary)
    }
}
