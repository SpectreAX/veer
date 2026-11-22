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
                FailurePanel(message: reason, log: log, startNetworkNotice: store.coreStartNetworkNotice)
                    .frame(maxWidth: Metrics.readingWidth)
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity)
            }
        } else {
            let starting = store.phase == .starting, profile = store.activeProfile != nil
            let detail = profile ? message : String(localized: "先导入一个配置。")
            let startNotice = starting ? nil : store.coreStartNetworkNotice
            StateView(symbol: symbol, title: starting ? String(localized: "内核正在启动…") : String(localized: "内核没有运行"),
                      message: detail, actionNotice: startNotice,
                      actionTitle: starting ? nil : profile ? String(localized: "启动") : String(localized: "导入配置…")) {
                if profile { store.start() } else { store.openImport() }
            }
        }
    }
}

extension ProxyStore {
    /// What Start and Retry can enable before the core begins carrying traffic.
    var coreStartNetworkNotice: String? {
        guard activeProfile != nil else { return nil }
        switch (settings.tun, systemProxyRemembered) {
        case (true, true): return String(localized: "启动时会打开系统代理，并尝试用 TUN 接管流量。")
        case (true, false): return String(localized: "启动时会尝试用 TUN 接管流量。若失败，将打开系统代理。")
        case (false, true): return String(localized: "启动后将打开系统代理。")
        case (false, false): return nil
        }
    }
}

/// Why the core could not start, its last lines, and the way back.
struct FailurePanel: View {
    @Environment(ProxyStore.self) private var store
    let message: String
    let log: [String]
    var startNetworkNotice: String?
    var logHeight: CGFloat = 180
    /// Where this is what to do next, and Return should do it.
    var retryIsDefault = false
    /// Retries that failed again at once. A port in use or a missing core fails without passing
    /// through starting, so the panel stays exactly as it was and says nothing unless counted here.
    /// A retry that does start goes through starting, which the start button's ring announces.
    @State private var immediateFailures = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            StatusBadge(kind: .failure, text: message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let notice = store.notice {
                StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true)
            }
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
            if let startNetworkNotice {
                Text(startNetworkNotice).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            // On a line of its own, as the row below is full in a narrow column. The way out if an update
            // is what stopped it starting; TUN runs the bundled one anyway.
            if store.hasUpdatedCore, !store.settings.tun {
                Button(String(localized: "恢复随附版本")) {
                    store.useBundledCore()
                    if !store.hasUpdatedCore { store.start() }
                }
                .neutralControl()
            }
            if let profile = store.activeProfile, store.page != .proxies || profile.isSubscription {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.sm) { profileActions(profile) }
                    VStack(alignment: .leading, spacing: Spacing.sm) { profileActions(profile) }
                }
            }
            HStack {
                SettingsLink { Text("打开设置…") }.neutralControl()
                Spacer()
                if immediateFailures > 0 {
                    Text(retryResult).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("重试") {
                    store.start()
                    // Only once the result is in: a start that is under way has not failed yet.
                    if case .failed = store.phase {
                        immediateFailures += 1
                        AccessibilityNotification.Announcement(retryResult).post()
                    }
                }
                .primaryAction(.regular)
                .keyboardShortcut(retryIsDefault ? .defaultAction : nil)
            }
        }
        .panel()
    }

    private var retryResult: String { String(localized: "仍然失败（第 \(String(immediateFailures)) 次重试）") }

    @ViewBuilder private func profileActions(_ profile: Profile) -> some View {
        Button("管理配置…") { store.manageProfiles() }.neutralControl()
        if profile.isSubscription {
            Button { store.update(profile.id) } label: {
                HStack(spacing: Spacing.xs) {
                    if store.updatingProfiles.contains(profile.id) { ProgressView().controlSize(.small) }
                    Text("更新订阅")
                }
            }
            .neutralControl()
            .disabled(store.updatingProfiles.contains(profile.id))
        }
    }
}
