import AppKit
import Testing
@testable import VeerApp

@MainActor struct StraySidebarItemsTests {
    @Test func onlyHiddenSidebarTogglesAreStray() {
        let toggle = #selector(NSSplitViewController.toggleSidebar(_:))
        let hidden = NSMenuItem(title: "隐藏边栏", action: toggle, keyEquivalent: "s")
        hidden.keyEquivalentModifierMask = [.option, .command]
        hidden.isHidden = true
        let visible = NSMenuItem(title: "隐藏边栏", action: toggle, keyEquivalent: "s")
        let otherHidden = NSMenuItem(title: "其他", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        otherHidden.isHidden = true

        let help = NSMenu(title: "帮助")
        help.items = [NSMenuItem(title: "Veer 帮助", action: nil, keyEquivalent: ""), hidden]
        let view = NSMenu(title: "显示")
        view.items = [visible, otherHidden]
        let main = NSMenu()
        for submenu in [view, help] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }

        #expect(StraySidebarItems.strays(in: main) == [hidden])
        // Disarmed, it answers nothing and is still found to be removed.
        StraySidebarItems.disarm(hidden)
        #expect(hidden.action == nil && hidden.keyEquivalent.isEmpty)
        #expect(StraySidebarItems.strays(in: main) == [hidden])
        StraySidebarItems.disarm(visible)
        #expect(visible.action == #selector(NSSplitViewController.toggleSidebar(_:)))
    }
}
