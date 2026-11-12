import SwiftUI

struct OverviewHero: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tapFeedback = 0
    @State private var spinning = false

    var body: some View {
        Group {
            if case let .failed(message, log) = store.phase {
                failure(message: message, log: log)
            } else {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    // At accessibility sizes the badge and uptime stack, so neither breaks mid-word.
                    let statusLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
                        : AnyLayout(HStackLayout(alignment: .top))
                    statusLayout {
                        StatusBadge(kind: statusKind, text: statusText)
                            .accessibilityIdentifier("overview-status")
                        if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                        if store.isRunning, let start = store.runningSince {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack(spacing: Spacing.xs) {
                                    Text("运行时间")
                                    Text(OverviewFormat.duration(start, now: context.date))
                                }
                            }
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityIdentifier("overview-uptime")
                        }
                    }
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l)) : AnyLayout(HStackLayout(spacing: Spacing.l))
                    layout {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        powerButton
                    }
                }
            }
        }
        .padding(20)
        .background(Color.cardBackground, in: .rect(cornerRadius: Radius.hero))
        .sensoryFeedback(.impact(weight: .medium), trigger: tapFeedback)
    }

    private var statusKind: StatusKind { store.isRunning ? .success : store.isStarting ? .info : .neutral }
    private var statusText: String {
        store.isRunning ? String(localized: "运行中") : store.isStarting ? String(localized: "正在启动") : String(localized: "已停止")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if store.isRunning {
                if let exit = store.exit, !exit.ip.isEmpty {
                    Text("\(exit.flag) \(exit.ip)")
                        .font(.title2.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .accessibilityLabel(String(localized: "出口 IP") + " " + exit.ip)
                        .accessibilityIdentifier("overview-exit-ip")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.xs) { exitDetails(exit) }
                        VStack(alignment: .leading, spacing: Spacing.xs) { exitDetails(exit) }
                    }
                } else {
                    Text(store.isCheckingExit ? String(localized: "正在检测…") : String(localized: "无法检测出口"))
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("overview-exit-ip")
                    if !store.isCheckingExit {
                        Button("重新检测") { store.recheckExit() }
                            .font(.subheadline).accessibilityIdentifier("overview-recheck-exit")
                    }
                }
            } else {
                Text(store.activeProfile?.name ?? "—").font(.title3.weight(.semibold))
                Text("启动后显示出口 IP。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func exitDetails(_ exit: ExitInfo) -> some View {
        if let organization = exit.organization, !organization.isEmpty {
            Text(organization).font(.subheadline).foregroundStyle(.secondary)
        }
        if let country = regionName(exit), !country.isEmpty { Tag(text: country) }
    }

    /// The lookup service answers in English; name the region in the UI language instead.
    private func regionName(_ exit: ExitInfo) -> String? {
        if let code = exit.countryCode, !code.isEmpty, let name = locale.localizedString(forRegionCode: code) {
            return name
        }
        return exit.country
    }

    private var powerButton: some View {
        Button {
            tapFeedback += 1
            if store.isRunning { store.stop() } else { store.start() }
        } label: {
            ZStack {
                Circle().fill(store.isRunning ? Color.quietFill : Color.accentFill)
                    .frame(width: 64, height: 64).opacity(store.isStarting ? 0.45 : 1)
                Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                    .font(.title2).foregroundStyle(store.isRunning ? Color.primary : Color.onAccent)
                if store.isStarting {
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(Color.veerAccent.opacity(reduceMotion ? 0.5 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                        .onAppear {
                            if !reduceMotion { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true } }
                        }
                        .onDisappear { spinning = false }
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(store.isStarting)
        .accessibilityLabel(store.isStarting ? String(localized: "正在启动") : store.isRunning ? String(localized: "停止内核") : String(localized: "启动内核"))
        .accessibilityIdentifier("overview-power")
    }

    private func failure(message: String, log: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            StatusBadge(kind: .failure, text: String(localized: "启动失败"))
                .accessibilityIdentifier("overview-status")
            // When there is no friendlier wording, the message is the core's raw error, which the
            // log box below already shows; don't print it twice.
            if !log.contains(where: { $0.contains(message) }) {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if !log.isEmpty {
                ScrollView {
                    Text(log.joined(separator: "\n")).font(.codeSmall).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(Spacing.m)
                }
                .frame(maxHeight: 120)
                .background(Color.quietFill, in: .rect(cornerRadius: Radius.code))
                .accessibilityIdentifier("overview-failure-log")
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Spacing.s)) : AnyLayout(HStackLayout(spacing: Spacing.s))
            layout {
                Button("重试") { store.start() }.buttonStyle(.primaryCapsule)
                    .accessibilityIdentifier("overview-retry")
                // Only a subscription can be updated; a pasted or file config has nothing to fetch.
                if let id = store.activeProfileID, store.canUpdate(id) {
                    Button("更新订阅") { store.update(id) }
                        .buttonStyle(.secondaryCapsule)
                        .disabled(store.updatingProfiles.contains(id))
                        .accessibilityIdentifier("overview-update-subscription")
                }
            }
        }
    }
}
