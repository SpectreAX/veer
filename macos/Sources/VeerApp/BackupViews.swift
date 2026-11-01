import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// File → Back Up and Restore, through the system's save and open panels.
enum BackupFlow {
    static func backUp(store: ProxyStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Veer \(Date.now.formatted(.iso8601.year().month().day())).zip"
        let links = NSButton(checkboxWithTitle: String(localized: "包含订阅链接（拿到这个文件的人可以用你的订阅）"), target: nil, action: nil)
        links.state = .off
        panel.accessoryView = padded(links)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Backup.make(paths: store.paths, defaults: .standard, profileStore: store.profileStore,
                            includeLinks: links.state == .on, appVersion: AboutSettings.version, to: url)
        } catch {
            show(error)
        }
    }

    /// Shows what the backup replaces and, once confirmed, restores it and opens Veer again so
    /// every part reads the restored files and settings.
    static func restore(store: ProxyStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let opened: (manifest: Backup.Manifest, folder: URL)
        do { opened = try Backup.open(url) } catch { return show(error) }
        let manifest = opened.manifest
        let alert = NSAlert()
        alert.messageText = String(localized: "从备份恢复？")
        let names = manifest.profiles.isEmpty ? String(localized: "无") : manifest.profiles.joined(separator: "、")
        let links = manifest.hasSubscriptionLinks ? String(localized: "包含订阅链接。") : String(localized: "不含订阅链接，恢复后订阅需要重新填写链接才能更新。")
        alert.informativeText = String(localized: "备份于 \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))（Veer \(manifest.appVersion)）。将替换现在的配置（\(names)）、我的分流、\(manifest.threads) 个 Agent 对话和设置。\(links) AI 的 Key 不在备份里，保持不变。完成后 Veer 会重新打开。")
        alert.addButton(withTitle: String(localized: "恢复"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? FileManager.default.removeItem(at: opened.folder.deletingLastPathComponent())
            return
        }
        // The core must not run on files that are being replaced.
        store.stop()
        do {
            try Backup.restore(from: opened.folder, paths: store.paths, defaults: .standard, profileStore: store.profileStore)
            AppLanguage.relaunch()
        } catch {
            show(error)
        }
    }

    private static func padded(_ view: NSView) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.fittingSize.width + 32, height: view.fittingSize.height + 16))
        view.frame.origin = NSPoint(x: 16, y: 8)
        container.addSubview(view)
        return container
    }

    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "操作没有完成")
        alert.informativeText = (error as? EditorError)?.message ?? error.localizedDescription
        alert.runModal()
    }
}

/// About → Export Diagnostics: every file of the bundle, readable before it is saved.
struct DiagnosticsSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Diagnostics.Item] = []
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("导出诊断包").font(.title3.weight(.semibold))
            Text("包含版本、设置、匿名化后的配置（服务器、密码和节点名都已替换）和最近的日志。不含 API Key 和订阅链接。日志里可能有你访问过的域名，导出前可以逐个查看。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Spacing.md) {
                List(items, selection: $selected) { Text($0.name).tag($0.name) }
                    .listStyle(.bordered)
                    .frame(width: 180)
                ScrollView {
                    Text(items.first { $0.name == selected }?.text ?? "")
                        .font(Typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                }
                .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("导出…") { export() }.keyboardShortcut(.defaultAction).primaryAction(.regular).disabled(items.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 680, height: 480)
        .task {
            items = await store.diagnosticItems()
            selected = items.first?.name
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Veer Diagnostics \(Date.now.formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Diagnostics.write(items, to: url)
            dismiss()
        } catch {
            store.notice = store.message(for: error)
        }
    }
}
