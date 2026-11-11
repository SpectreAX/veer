import AppKit

/// SwiftUI puts a hidden "Hide Sidebar ⌥⌘S" in the Help menu that sends AppKit's `toggleSidebar:`.
/// Hidden, it still answers its shortcut, which collapses the split view without `SidebarAnimator` and
/// out of step with View → Hide Sidebar (⌃⌘S). SwiftUI offers no way to leave it out, so AppKit takes
/// it out each time the menu gains or changes it. SwiftUI can add it again as the menus update for a
/// key press, so it loses its shortcut and action at once, and leaves the menu once SwiftUI is done.
@MainActor enum StraySidebarItems {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        removeAll()
        observers = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                // Posted on the main thread, where the menus live.
                nonisolated(unsafe) let menu = note.object as? NSMenu
                let index = note.userInfo?["NSMenuItemIndex"] as? Int
                MainActor.assumeIsolated {
                    if let menu, let index, menu.items.indices.contains(index) { disarm(menu.items[index]) }
                    // Removed after SwiftUI has finished filling the menu, never in the middle of it.
                    Task { @MainActor in removeAll() }
                }
            }
        }
    }

    static func removeAll() {
        guard let menu = NSApp.mainMenu else { return }
        for item in strays(in: menu) { item.menu?.removeItem(item) }
    }

    /// Leaves it nothing to answer or send. Only a stray changes, so the change it posts is ignored.
    static func disarm(_ item: NSMenuItem) {
        guard isStray(item), item.action != nil else { return }
        item.identifier = disarmed
        item.keyEquivalent = ""
        item.action = nil
    }

    private static let disarmed = NSUserInterfaceItemIdentifier("veer.straySidebarItem")

    static func isStray(_ item: NSMenuItem) -> Bool {
        item.identifier == disarmed || item.isHidden && item.action == #selector(NSSplitViewController.toggleSidebar(_:))
    }

    /// Hidden items that toggle the sidebar, in `menu` and its submenus. The visible View menu item
    /// is Veer's own and stays.
    static func strays(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            let own = isStray(item) ? [item] : []
            return own + (item.submenu.map(strays(in:)) ?? [])
        }
    }
}
