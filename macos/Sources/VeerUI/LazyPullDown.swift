import AppKit
import SwiftUI

/// One line of the menu.
public struct PullDownEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Chosen with `id`.
        case item(id: String)
        case submenu([PullDownEntry])
        case separator
    }

    public let title: String
    public let checked: Bool
    public let kind: Kind

    public init(title: String, checked: Bool = false, kind: Kind) {
        self.title = title
        self.checked = checked
        self.kind = kind
    }

    public static let separator = PullDownEntry(title: "", kind: .separator)
}

/// A borderless pull-down menu, a line of text, whose items are made only as it opens.
///
/// AppKit: on macOS a SwiftUI `Menu` makes every one of its items, buttons and submenus alike, each
/// time its view updates. A page of policy groups with a few hundred members each kept thousands
/// of items alive and made them again with every change of the page. `NSPopUpButton` asks its
/// menu's delegate for the items when the menu is about to open (`menuNeedsUpdate`), so here they
/// are made then, from what is true at that moment, and never otherwise.
public struct LazyPullDown: NSViewRepresentable {
    let title: String
    let font: NSFont.TextStyle
    let truncation: NSLineBreakMode
    let help: String
    let label: String
    let value: String
    let entries: () -> [PullDownEntry]
    let choose: (String) -> Void

    /// `title` is what the closed menu shows, cut short with `truncation` in the width it is given.
    /// `label` and `value` are what VoiceOver says: which menu, and what it is set to.
    public init(title: String, font: NSFont.TextStyle = .body, truncation: NSLineBreakMode = .byTruncatingTail, help: String,
                label: String, value: String, entries: @escaping () -> [PullDownEntry], choose: @escaping (String) -> Void) {
        self.title = title
        self.font = font
        self.truncation = truncation
        self.help = help
        self.label = label
        self.value = value
        self.entries = entries
        self.choose = choose
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // The first item of a pull-down is its title, never shown in the open menu.
        button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        button.menu?.delegate = context.coordinator
        update(button, context: context)
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: Context) { update(button, context: context) }

    private func update(_ button: NSPopUpButton, context: Context) {
        context.coordinator.entries = entries
        context.coordinator.choose = choose
        let font = NSFont.preferredFont(forTextStyle: font)
        if button.font != font {
            button.font = font
            // The button's font is also its menu's: the open menu keeps the system's menu size.
            button.menu?.font = .menuFont(ofSize: 0)
        }
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = truncation
        if button.menu?.items.first?.title != title { button.menu?.items.first?.title = title }
        // An open menu keeps its items; a stale title item is put right as it opens again.
        button.toolTip = help
        // VoiceOver reaches the pop-up button's cell, which otherwise reads the title, arrow and all.
        for element in [button, button.cell].compactMap({ $0 as? NSAccessibilityProtocol & NSObject }) {
            element.setAccessibilityLabel(label)
            element.setAccessibilityTitle(label)
            element.setAccessibilityValue(value)
        }
    }

    /// Its own width, or the width it is given when that is less: it truncates rather than pushes.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let own = nsView.intrinsicContentSize
        let width = proposal.width.map { min($0, own.width) } ?? own.width
        return CGSize(width: max(0, width), height: own.height)
    }

    @MainActor public final class Coordinator: NSObject, NSMenuDelegate {
        var entries: () -> [PullDownEntry] = { [] }
        var choose: (String) -> Void = { _ in }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            // Keep the title item; everything after it is made again from what is true now.
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            for item in Self.items(entries(), target: self) { menu.addItem(item) }
        }

        /// Menu items for `entries`, each choosing through `target`.
        static func items(_ entries: [PullDownEntry], target: Coordinator) -> [NSMenuItem] {
            entries.map { entry in
                switch entry.kind {
                case .separator:
                    return NSMenuItem.separator()
                case .item(let id):
                    let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.chosen(_:)), keyEquivalent: "")
                    item.target = target
                    item.representedObject = id
                    item.state = entry.checked ? .on : .off
                    return item
                case .submenu(let children):
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.state = entry.checked ? .on : .off
                    let submenu = NSMenu(title: entry.title)
                    for child in items(children, target: target) { submenu.addItem(child) }
                    item.submenu = submenu
                    return item
                }
            }
        }

        @objc func chosen(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { choose(id) }
        }
    }
}
