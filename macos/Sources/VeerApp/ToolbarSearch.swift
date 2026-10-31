import AppKit
import SwiftUI
import VeerUI

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
    @Binding var text: String
    let prompt: Text

    var body: some View {
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
        .frame(width: 190)
    }
}
