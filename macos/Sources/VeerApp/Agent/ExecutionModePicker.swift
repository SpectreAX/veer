import SwiftUI
import VeerCore

/// Composer button for how much the conversation may do without asking, with a menu like Claude's
/// mode menu: a system button like the composer's others. 完整权限's symbol is in the warning color,
/// as Codex marks full access; each mode also has a symbol of its own, so color is not the only sign.
struct ExecutionModePicker: View {
    @Environment(AgentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let mode = store.executionMode
        let tint: Color? = mode == .full ? .statusWarning : nil
        Button { store.showingExecutionModePicker.toggle() } label: {
            // Only full access is colored; otherwise the symbol keeps the system's label color, which
            // follows the window's state like the composer's other buttons.
            if let tint { Image(systemName: mode.symbol).foregroundStyle(tint) } else { Image(systemName: mode.symbol) }
        }
        .composerOption()
        .help(String(localized: "执行模式：\(mode.title)。\(mode.detail)"))
        .accessibilityLabel(String(localized: "执行模式：\(mode.title)"))
        .popover(isPresented: $store.showingExecutionModePicker, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "执行模式")).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.bottom, Spacing.xxs)
                ForEach(Array(ExecutionMode.allCases.enumerated()), id: \.element) { index, choice in
                    ChoiceRow(number: index + 1, symbol: choice.symbol, title: choice.title, detail: choice.detail,
                              selected: choice == mode, tint: choice == .full ? .statusWarning : nil) {
                        store.executionMode = choice
                        store.showingExecutionModePicker = false
                    }
                }
                Text(String(localized: "应用的修改都记在“我的分流”里，随时可以撤销；订阅原文不会改变。")).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.xs)
            }
            .padding(Spacing.sm)
            .frame(width: 380)
        }
    }
}
