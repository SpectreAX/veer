import SwiftUI
import VeerProxy

/// What is running, through which profile and mode, and whether apps use it.
struct OverviewView: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        if store.profiles.isEmpty {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "导入订阅链接、配置文件或节点分享链接后，Veer 会启动内核并按配置分流。"),
                      actionTitle: String(localized: "导入配置…")) { store.openImport() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    statusPanel
                    if case .failed(let message, let log) = store.phase { failurePanel(message, log) }
                    if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
                    if store.isRunning { exitsPanel }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                StatusBadge(kind: store.phase.kind, text: store.phase.title).font(.title3.weight(.semibold))
                Spacer()
                if store.isRunning {
                    HStack(spacing: Spacing.lg) {
                        Label(Format.rate(store.uploadRate), systemImage: "arrow.up").help("上传速率")
                        Label(Format.rate(store.downloadRate), systemImage: "arrow.down").help("下载速率")
                    }
                    .font(Typography.code)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.sm) {
                GridRow {
                    Text("使用的配置").foregroundStyle(.secondary)
                    Text(store.activeProfile?.name ?? String(localized: "未选择")).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("模式").foregroundStyle(.secondary)
                    Text(store.mode.title)
                }
                GridRow {
                    Text("代理端口").foregroundStyle(.secondary)
                    Text(verbatim: "127.0.0.1:\(store.proxyPort)").font(Typography.code).textSelection(.enabled)
                }
            }
            Divider()
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("系统代理")
                    Text(store.isRunning ? String(localized: "让浏览器和大多数 App 经过 Veer。关闭或退出 Veer 时，恢复原来的代理设置。") : String(localized: "内核运行后才能开启。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("系统代理", isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!store.isRunning)
            }
        }
        .panel()
    }

    private func failurePanel(_ message: String, _ log: [String]) -> some View {
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
                .frame(maxHeight: 180)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            HStack {
                SettingsLink { Text("打开设置…") }.neutralControl()
                Spacer()
                Button("重试") { store.start() }.buttonStyle(.borderedProminent)
            }
        }
        .panel()
    }

    /// Where traffic goes now: each select group and what it uses.
    private var exitsPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("当前出口").font(.headline)
            ForEach(store.groups.filter(\.isSelectable).prefix(8)) { group in
                HStack {
                    Text(group.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(group.now ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
            }
        }
        .panel()
    }
}
