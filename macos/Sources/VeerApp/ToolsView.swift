import SwiftUI
import VeerProxy

/// Useful things that do not need a place in the sidebar: diagnostics open as subpages, the rest act
/// at once. Settings keep their own window, as on any Mac.
struct ToolsView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Form {
            Section(String(localized: "诊断")) {
                ToolRow(title: Page.requests.title, detail: String(localized: "最近结束的连接，可以搜索和添加规则"),
                        symbol: Page.requests.symbol, opensPage: true) { store.page = .requests }
                ToolRow(title: String(localized: "DNS 查询"), detail: String(localized: "用内核的 DNS 设置解析域名"),
                        symbol: Page.dns.symbol, opensPage: true) { store.page = .dns }
                ToolRow(title: Page.logs.title, detail: String(localized: "内核的实时日志"), symbol: Page.logs.symbol, opensPage: true) { store.page = .logs }
            }
            Section(String(localized: "数据")) {
                ToolRow(title: String(localized: "导出配置…"), detail: String(localized: "合并“我的分流”后的 mihomo YAML"), symbol: "square.and.arrow.up") {
                    if let profile = store.activeProfile { ConfigExport.run(profile, store: store) }
                }
                .disabled(store.activeProfile == nil)
                ToolRow(title: String(localized: "备份…"), detail: String(localized: "把配置、我的分流、Agent 对话和设置存成一个文件"),
                        symbol: "externaldrive") { BackupFlow.backUp(store: store) }
                ToolRow(title: String(localized: "从备份恢复…"), detail: String(localized: "替换现在的配置和设置，完成后 Veer 会重新打开"),
                        symbol: "arrow.counterclockwise") { BackupFlow.restore(store: store) }
            }
            Section(String(localized: "更多")) {
                ToolRow(title: String(localized: "设置…"), detail: String(localized: "语言、代理、DNS、TUN 和快捷键"), symbol: "gearshape") { openSettings() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
    }
}

/// A whole row that is one button; a chevron says it opens a page rather than acting.
private struct ToolRow: View {
    let title: String
    let detail: String
    let symbol: String
    var opensPage = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: Spacing.xl)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.sm)
                if opensPage {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
