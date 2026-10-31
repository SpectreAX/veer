import AppKit
import SwiftUI
import VeerProxy

/// The core's log while it runs: filter by level, search, pause, copy.
struct LogsView: View {
    @Environment(ProxyStore.self) private var store
    @State private var level: Level
    @State private var query = ""
    @State private var selection = Set<LogEntry.ID>()

    init(level: Level = .all) {
        _level = State(initialValue: level)
    }

    enum Level: String, CaseIterable, Identifiable {
        case all, info, warning, error, debug
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .info: String(localized: "信息")
            case .warning: String(localized: "警告")
            case .error: String(localized: "错误")
            case .debug: String(localized: "调试")
            }
        }
    }

    private var shown: [LogEntry] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.logs.filter { entry in
            (level == .all || entry.level == level.rawValue) && (text.isEmpty || entry.message.lowercased().contains(text))
        }
    }

    var body: some View {
        content
            .pageToolbar(.logs) {
                Button { store.logsPaused.toggle() } label: {
                    store.logsPaused ? Label("继续", systemImage: "play") : Label("暂停", systemImage: "pause")
                }
                .help(store.logsPaused ? String(localized: "继续记录日志") : String(localized: "暂停记录日志"))
                Button { copy(shown) } label: { Label("复制", systemImage: "doc.on.doc") }
                    .help("复制显示的日志")
                    .disabled(shown.isEmpty)
                Button { store.clearLogs() } label: { Label("清空", systemImage: "trash") }
                    .help("清空日志")
                    .disabled(store.logs.isEmpty)
            } content: {
                ToolbarSearchField(text: $query, prompt: Text("搜索日志"))
            }
    }

    @ViewBuilder private var content: some View {
        if !store.isRunning && store.logs.isEmpty {
            StateView(symbol: Page.logs.symbol, title: String(localized: "内核没有运行"), message: String(localized: "启动后，内核的日志会实时显示在这里。"))
        } else {
            VStack(spacing: 0) {
                // Above the empty state too: a level with no entries must not take away the way back.
                HStack {
                    SegmentedControl(label: String(localized: "级别"), selection: $level,
                                     options: Level.allCases.map { .init(value: $0, title: $0.title) })
                        .fixedSize()
                    Spacer()
                    Text("\(shown.count) 条").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                Divider()
                if shown.isEmpty {
                    StateView(symbol: Page.logs.symbol,
                              title: store.logs.isEmpty ? String(localized: "还没有日志") : String(localized: "没有匹配的日志"),
                              // The core sends only what its level lets through, which may be why this one is empty.
                              message: query.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? String(localized: "日志级别是“\(store.settings.logLevel)”，可以在设置中调整。") : nil,
                              actionTitle: level != .all && !store.logs.isEmpty ? String(localized: "显示全部级别") : nil) { level = .all }
                } else {
                    logList
                }
            }
        }
    }

    private var logList: some View {
        Group {
            ScrollViewReader { proxy in
                List(shown, selection: $selection) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(entry.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary)
                        Text(verbatim: entry.level.uppercased()).foregroundStyle(color(entry.level)).frame(width: 56, alignment: .leading)
                        Text(entry.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.codeSmall)
                    .id(entry.id)
                }
                .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
                    Button("复制") { copy(shown.filter { ids.contains($0.id) }) }
                }
                .onChange(of: store.logs.last?.id) { _, last in
                    if !store.logsPaused, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": .statusFailure
        case "warning": .statusWarning
        case "debug": .secondary
        default: .statusInfo
        }
    }

    private func copy(_ entries: [LogEntry]) {
        let text = entries.map { "\($0.time.formatted(date: .omitted, time: .standard)) \($0.level.uppercased()) \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
