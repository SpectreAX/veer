import AppKit
import SwiftUI

final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: EditorModel?
    // Objective-C forwarding hooks are nonisolated, but AppKit dispatches this
    // window delegate on the main thread. Enforce that contract at both hooks;
    // do not send the legacy delegate across a task or actor boundary.
    nonisolated(unsafe) private var originalWindowDelegate: (any NSWindowDelegate)?

    func protect(_ window: NSWindow, model: EditorModel) {
        self.model = model
        guard window.delegate !== self else { return }
        originalWindowDelegate = window.delegate
        window.delegate = self
    }

    private func mayDiscard(_ action: String) -> Bool {
        guard let model else { return true }
        // With encrypted sessions, drafts survive quitting; only an in-flight request is lost.
        guard model.busy || (!model.persistsSessions && model.session.hasUnsavedChanges) else { return true }
        let alert = NSAlert()
        alert.messageText = "\(action) Veer 编辑器？"
        alert.informativeText = model.persistsSessions
            ? "进行中的请求会停止，不会写入草稿。会话与已写入的草稿已加密保存在本机。"
            : "未导出的规则和登记组名只在内存中。规则导出不包含组名地区登记；请确认已保存需要的内容。进行中的请求也会停止等待。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃并\(action)")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        model.cancel()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mayDiscard("关闭") else { return false }
        return originalWindowDelegate?.windowShouldClose?(sender) ?? true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mayDiscard("退出") ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.flushSave(); model?.stopService() }

    // Keep SwiftUI's own delegate behavior for selectors this guard does not handle.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        precondition(Thread.isMainThread)
        return originalWindowDelegate?.responds(to: selector) ?? false
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        precondition(Thread.isMainThread)
        return originalWindowDelegate
    }
}

struct WindowProtection: NSViewRepresentable {
    let lifecycle: AppLifecycle
    let model: EditorModel
    func makeNSView(context: Context) -> ProtectionView {
        let view = ProtectionView(); view.lifecycle = lifecycle; view.model = model; return view
    }
    func updateNSView(_ view: ProtectionView, context: Context) {}

    final class ProtectionView: NSView {
        weak var lifecycle: AppLifecycle?
        weak var model: EditorModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, let lifecycle, let model { lifecycle.protect(window, model: model) }
        }
    }
}
