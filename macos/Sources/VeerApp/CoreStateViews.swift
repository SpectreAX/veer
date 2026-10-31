import SwiftUI
import VeerProxy
import VeerUI

/// In place of a page that needs the core and has nothing to show: why it isn't running, and the way
/// to start it, since every page has the button that may have caused a failure.
struct CoreNotRunningView: View {
    @Environment(ProxyStore.self) private var store
    let symbol: String
    let message: String

    var body: some View {
        if case .failed(let reason, let log) = store.phase {
            // In a scroll view, as on the overview: at its full height, wrapped text here pushed the
            // whole window out of place, the sidebar and the top row with it.
            ScrollView {
                FailurePanel(message: reason, log: log)
                    .frame(maxWidth: Metrics.readingWidth)
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity)
            }
        } else {
            let starting = store.phase == .starting, profile = store.activeProfile != nil
            StateView(symbol: symbol, title: starting ? String(localized: "内核正在启动…") : String(localized: "内核没有运行"),
                      message: profile ? message : String(localized: "先导入一个配置。"),
                      actionTitle: starting ? nil : profile ? String(localized: "启动") : String(localized: "导入配置…")) {
                if profile { store.start() } else { store.openImport() }
            }
        }
    }
}

/// Why the core could not start, its last lines, and the way back.
struct FailurePanel: View {
    @Environment(ProxyStore.self) private var store
    let message: String
    let log: [String]
    var logHeight: CGFloat = 180
    /// Where this is what to do next, and Return should do it.
    var retryIsDefault = false
    @State private var retries = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            StatusBadge(kind: .failure, text: message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !log.isEmpty {
                ScrollView {
                    Text(log.suffix(12).joined(separator: "\n"))
                        .font(Typography.codeSmall)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // As tall as a short log needs, not always the most it may take.
                .frame(maxHeight: logHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            HStack {
                SettingsLink { Text("打开设置…") }.neutralControl()
                Spacer()
                // A cause that hasn't gone fails at once with the same words, which looks like nothing happened.
                if retries > 0 {
                    Text(retryResult).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("重试") {
                    retries += 1
                    store.start()
                    AccessibilityNotification.Announcement(retryResult).post()
                }
                .primaryAction(.regular)
                .keyboardShortcut(retryIsDefault ? .defaultAction : nil)
            }
        }
        .panel()
    }

    private var retryResult: String { String(localized: "仍然失败（第 \(String(retries)) 次重试）") }
}
