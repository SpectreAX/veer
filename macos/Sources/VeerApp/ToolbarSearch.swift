import AppKit
import SwiftUI
import VeerUI

enum ToolbarSearchFocus {
    /// Puts the cursor in the key window's toolbar field. By hand: `@FocusState` doesn't reach a
    /// field hosted in the toolbar.
    static func focus() {
        guard let window = NSApp.keyWindow, let frame = window.contentView?.superview else { return }
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return field.isEditable ? [field] : [] }
            return view.subviews.flatMap(fields)
        }
        // Above the content area: a page's own fields stay out of it.
        let field = fields(frame).first { $0.convert($0.bounds, to: nil).midY > window.contentLayoutRect.maxY }
        if let field { window.makeFirstResponder(field) }
    }
}

extension View {
    /// A search field in the toolbar, for pages with something to filter. Not `.searchable`: its
    /// toolbar item has one fixed identifier, and going straight from one page with a field to
    /// another could insert the new item before removing the old, which NSToolbar answers by
    /// raising an exception that ends the app.
    func toolbarSearch(_ text: Binding<String>, prompt: Text) -> some View {
        modifier(ToolbarSearch(text: text, prompt: prompt))
    }
}

private struct ToolbarSearch: ViewModifier {
    @Binding var text: String
    let prompt: Text

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) { field }
            }
    }

    private var field: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "搜索"), text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .labelsHidden()
                .onExitCommand {
                    text = ""
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "清除搜索"))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 280)
    }
}
