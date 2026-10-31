import AppKit
import VeerProxy

/// Says why TUN needs a privileged helper before Veer registers it. A plain alert: the toggle can be
/// in the main window, in Settings or in the menu bar, and the main window may not be open.
enum HelperPrompt {
    static func alert(for consent: HelperState.TUNConsent) -> NSAlert {
        let alert = NSAlert()
        switch consent {
        case .install:
            alert.messageText = String(localized: "需要安装后台服务")
            alert.informativeText = [
                String(localized: "Veer 需要一个以管理员权限运行的后台服务，才能用 TUN 管理网络路由并运行内核。"),
                String(localized: "安装后，在系统设置的“登录项”中允许 Veer，即可完成设置。"),
                String(localized: "在允许之前，Veer 会先用系统代理。"),
            ].joined(separator: "\n\n")
            alert.addButton(withTitle: String(localized: "安装"))
        case .approve:
            alert.messageText = String(localized: "需要在系统设置中允许")
            alert.informativeText = [
                String(localized: "在系统设置的“登录项”中允许 Veer 后，TUN 才能生效。"),
                String(localized: "在允许之前，Veer 会先用系统代理。"),
            ].joined(separator: "\n\n")
            alert.addButton(withTitle: String(localized: "打开系统设置"))
        }
        // Later, not Cancel: nothing is being called off, and it can be done from here any time.
        alert.addButton(withTitle: String(localized: "稍后")).keyEquivalent = "\u{1b}"
        return alert
    }

    /// Whether the person agreed.
    static func ask(_ consent: HelperState.TUNConsent) -> Bool {
        NSApp.activate()
        return alert(for: consent).runModal() == .alertFirstButtonReturn
    }
}
