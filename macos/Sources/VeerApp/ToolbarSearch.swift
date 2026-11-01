import AppKit
import SwiftUI
import VeerUI

extension ProxyStore {
    /// Whether this page has a search field and something to search. Not by what is showing: a page
    /// that empties as you type must keep the field, and the cursor in it.
    var canSearch: Bool {
        switch page {
        case .proxies: isRunning && !groups.isEmpty
        case .connections: isRunning
        case .requests: !requests.isEmpty
        case .logs: !logs.isEmpty
        default: false
        }
    }
}

enum ToolbarSearchFocus {
    /// Puts the cursor in the key window's capsule field. By hand: the shortcut lives in the app's
    /// commands, which have no way into the page that made the field.
    static func focus() {
        guard let window = NSApp.keyWindow, let frame = window.contentView?.superview else { return }
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return field.isEditable ? [field] : [] }
            return view.subviews.flatMap(fields)
        }
        // In the window's top row: a page's own fields stay out of it. Measured from the window, as
        // in full screen, with no toolbar, the content area reaches the top.
        let field = fields(frame).first { $0.convert($0.bounds, to: nil).midY > window.frame.height - MainView.topRowHeight }
        if let field { window.makeFirstResponder(field) }
    }
}

/// A search field for a page's toolbar (⌘F focuses it). Not `.searchable`: its toolbar item has one
/// fixed identifier, and going straight from one page with a field to another could insert the new
/// item before removing the old, which NSToolbar answers by raising an exception that ends the app.
struct ToolbarSearchField: View {
    @Environment(ProxyStore.self) private var store
    @Binding var text: String
    /// Short: the field is narrow, and a longer prompt runs out of room in English first.
    let prompt: Text
    /// What it searches, when the prompt doesn't say.
    var help: String?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).opacity(store.canSearch ? 1 : 0.5)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(String(localized: "清除搜索"))
                    .accessibilityLabel(String(localized: "清除搜索"))
            }
        }
        .disabled(!store.canSearch)
        // Not left behind in a field that can't be cleared, to filter whatever comes next.
        .onChange(of: store.canSearch) { _, can in if !can { text = "" } }
        .padding(.horizontal, Spacing.sm)
        .frame(width: 190)
    }

    @ViewBuilder private var field: some View {
        let field = TextField(String(localized: "搜索"), text: $text, prompt: prompt)
            .textFieldStyle(.plain)
            .labelsHidden()
            .onExitCommand {
                text = ""
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        if let help { field.help(help) } else { field }
    }
}
