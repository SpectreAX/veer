import AppKit
import SwiftUI

extension FocusedValues {
    /// The sidebar of the window in front, so View → Hide Sidebar acts on it and is unavailable
    /// when that window has none (Settings, or no window at all).
    @Entry var sidebar: SidebarAnimator?
}

/// View → Show / Hide Sidebar, with the same animation as the window's button.
struct SidebarMenuButton: View {
    let sidebar: SidebarAnimator?

    var body: some View {
        Button(sidebar?.isHidden == true ? String(localized: "显示边栏") : String(localized: "隐藏边栏")) {
            sidebar?.toggle(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .disabled(sidebar == nil)
    }
}
