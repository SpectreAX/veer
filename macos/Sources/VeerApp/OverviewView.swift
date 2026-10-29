import SwiftUI
import VeerCore
import VeerProxy

/// The dashboard: status and exit, traffic, mode and switches, profile, services, connections and
/// groups, as cards in a grid that reflows with the window.
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
                    if case .failed(let message, let log) = store.phase { FailurePanel(message: message, log: log) }
                    if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
                    // Rows of two equal halves: cards shrink with the window (a Grid sizes cells to
                    // their widest content and overflowed it).
                    row { StatusCard() } right: { pair { TrafficCard(direction: .upload) } and: { TrafficCard(direction: .download) } }
                    row { ModeCard() } right: { pair { SystemProxyCard() } and: { TUNCard() } }
                    row { pair { NetworkCard() } and: { ProfileCard() } } right: { pair { ServicesCard() } and: { ConnectionsCard() } }
                    if store.isRunning { GroupsCard() }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .task(id: store.isRunning) {
                guard store.isRunning else { return }
                if store.exit == nil { store.checkExit() }
                // Service latency now and once a minute while the dashboard is open.
                while !Task.isCancelled {
                    store.checkServices()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }
}

extension OverviewView {
    /// Two halves of equal width and height.
    func row<Left: View, Right: View>(@ViewBuilder _ left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            left().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            right().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func pair<Left: View, Right: View>(@ViewBuilder _ left: () -> Left, @ViewBuilder and right: () -> Right) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            left().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            right().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A dashboard card: a title row with an icon, then content.
private struct Card<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }
}

/// Running or not, where traffic leaves, for how long, and the one big start/stop button.
private struct StatusCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "状态"), symbol: "waveform.path.ecg") {
            StatusBadge(kind: store.phase.kind, text: store.phase.title, compact: true)
        } content: {
            HStack(alignment: .center, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    exit
                    HStack(spacing: Spacing.xl) {
                        LabeledValue(String(localized: "运行时间")) {
                            if let since = store.runningSince, store.isRunning {
                                TimelineView(.periodic(from: since, by: 1)) { context in
                                    Text(verbatim: Format.duration(since: since, now: context.date)).monospacedDigit()
                                }
                            } else { Text(verbatim: "—") }
                        }
                        LabeledValue(String(localized: "网络")) {
                            Text(store.exit?.organization ?? "—").lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                Spacer(minLength: 0)
                startButton
            }
        }
    }

    @ViewBuilder private var exit: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            if store.isRunning, let exit = store.exit, !exit.ip.isEmpty {
                if !exit.flag.isEmpty { Text(exit.flag).font(.title) }
                Text(exit.ip).font(.system(.title, design: .rounded).weight(.semibold)).textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if let country = exit.country { Tag(text: country) }
            } else if store.isRunning, store.exit == .unknown {
                Text("无法检测出口").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } else if store.isRunning {
                ProgressView().controlSize(.small)
                Text("正在检测出口…").font(.title3).foregroundStyle(.secondary)
            } else {
                Text(store.activeProfile?.name ?? "").font(.title3.weight(.semibold)).lineLimit(1)
            }
            if store.isRunning {
                Button { store.checkExit() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("重新检测出口")
                    .accessibilityLabel(String(localized: "重新检测出口"))
            }
        }
    }

    private var startButton: some View {
        Button { store.isRunning ? store.stop() : store.start() } label: {
            Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                .font(.title.weight(.semibold))
                .frame(width: 64, height: 64)
        }
        .buttonBorderShape(.circle)
        .primaryAction()
        .disabled(store.phase == .starting || store.activeProfile == nil)
        .help(store.isRunning ? String(localized: "停止内核（⌘R）") : String(localized: "启动内核（⌘R）"))
        .accessibilityLabel(store.isRunning ? String(localized: "停止") : String(localized: "启动"))
    }
}

private struct LabeledValue<Value: View>: View {
    let title: String
    @ViewBuilder var value: () -> Value

    init(_ title: String, @ViewBuilder value: @escaping () -> Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value().font(.callout)
        }
    }
}

/// Upload or download: speed now, the fastest second, and the total of this run.
private struct TrafficCard: View {
    @Environment(ProxyStore.self) private var store
    enum Direction { case upload, download }
    let direction: Direction

    var body: some View {
        let up = direction == .upload
        Card(up ? String(localized: "上传") : String(localized: "下载"), symbol: up ? "arrow.up" : "arrow.down") {
            Text("峰值 \(Format.rate(up ? store.uploadPeak : store.downloadPeak))").font(.caption).foregroundStyle(.secondary)
        } content: {
            Text(verbatim: Format.rate(up ? store.uploadRate : store.downloadRate))
                .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            Text("本次共 \(Format.bytes(up ? store.uploadTotal : store.downloadTotal))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ModeCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "出站模式"), symbol: "arrow.triangle.branch") {
            SegmentedControl(label: String(localized: "模式"), selection: Binding(get: { store.mode }, set: { store.setMode($0) }),
                             options: ProxyStore.Mode.allCases.map { .init(value: $0, title: $0.title) })
                .controlSize(.large)
                .disabled(!store.isRunning)
        }
    }
}

private struct SystemProxyCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "系统代理"), symbol: "network") {
            Toggle(String(localized: "系统代理"), isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!store.isRunning)
        } content: {
            Text(store.tunActive ? String(localized: "TUN 已接管全部流量") : String(localized: "端口 \(String(store.proxyPort))"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// All traffic through a TUN device, run as root by the helper.
private struct TUNCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "TUN"), symbol: "shield.lefthalf.filled") {
            Toggle(String(localized: "TUN"), isOn: Binding(get: { store.settings.tun }, set: { store.setTUN($0) }))
                .toggleStyle(.switch).labelsHidden()
        } content: {
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var status: String {
        if store.tunActive { return String(localized: "运行中") }
        if !store.settings.tun { return String(localized: "已关闭") }
        return store.isRunning ? String(localized: "未生效，已改用系统代理") : String(localized: "启动后生效")
    }
}

/// This Mac's address on the local network, and whether devices there may use the proxy.
private struct NetworkCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Card(String(localized: "局域网"), symbol: "wifi") {
            Toggle(String(localized: "允许局域网设备连接"), isOn: $store.settings.allowLAN)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help("允许局域网设备连接")
        } content: {
            Text(verbatim: ProxyStore.localAddress ?? "—").font(.system(.title3, design: .rounded).weight(.semibold)).textSelection(.enabled)
            Text(store.settings.allowLAN ? String(localized: "允许局域网设备连接") : String(localized: "仅本机可用"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The profile in use: when it was updated and how much of the subscription is left.
private struct ProfileCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "配置"), symbol: "doc.text") {
            if let profile = store.activeProfile, profile.isSubscription {
                Button { store.update(profile.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(store.updatingProfiles.contains(profile.id))
                    .help("更新订阅")
                    .accessibilityLabel(String(localized: "更新订阅"))
            }
        } content: {
            if let profile = store.activeProfile {
                Button { store.page = .profiles } label: {
                    Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                Text("更新于 \(Format.relative(profile.updatedAt))").font(.caption).foregroundStyle(.secondary)
                if let usage = profile.usage, let total = usage.total, total > 0 {
                    let used = (usage.upload ?? 0) + (usage.download ?? 0)
                    ProgressView(value: min(1, Double(used) / Double(total))).tint(Color.veerAccent)
                    HStack {
                        Text(verbatim: "\(Format.bytes(used)) / \(Format.bytes(total))").font(.caption).monospacedDigit()
                        Spacer()
                        if let expire = usage.expire {
                            let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: expire).day ?? 0)
                            Text("剩 \(days) 天").font(.caption).foregroundStyle(days <= 3 ? Color.statusWarning : .secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Whether common sites answer through the proxy, and how fast.
private struct ServicesCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "服务状态"), symbol: "checkmark.shield") {
            Button { store.checkServices() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(!store.isRunning)
                .help("重新检测")
                .accessibilityLabel(String(localized: "重新检测"))
        } content: {
            Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.xs) {
                ForEach(ProxyStore.services, id: \.name) { service in
                    GridRow {
                        Label(service.name, systemImage: service.symbol).font(.callout).lineLimit(1)
                        delay(store.serviceDelays[service.name])
                    }
                }
            }
        }
    }

    @ViewBuilder private func delay(_ value: Int?) -> some View {
        if !store.isRunning {
            Text(verbatim: "—").foregroundStyle(.secondary)
        } else if let value {
            // A whole HTTPS request through the proxy, so slower than a node's delay test.
            Text(Format.delay(value)).font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? Color.statusFailure : value < 1000 ? Color.statusSuccess : value < 2500 ? Color.statusWarning : Color.statusFailure)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

private struct ConnectionsCard: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        Card(String(localized: "连接"), symbol: Page.connections.symbol) {
            Button { store.page = .connections } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("打开连接页")
                .accessibilityLabel(String(localized: "打开连接页"))
        } content: {
            Text(verbatim: store.isRunning ? String(store.connectionCount) : "—")
                .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("个活动连接").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Every select group with the node it uses, switchable in place.
private struct GroupsCard: View {
    @Environment(ProxyStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Spacing.md)]

    var body: some View {
        Card(String(localized: "策略组"), symbol: "square.stack.3d.up") {
            Button { store.page = .proxies } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("打开代理页")
                .accessibilityLabel(String(localized: "打开代理页"))
        } content: {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                ForEach(store.groups.filter(\.isSelectable)) { group in
                    HStack(spacing: Spacing.sm) {
                        Text(group.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.sm)
                        Menu {
                            ForEach(group.members) { member in
                                Button { store.select(member.name, in: group.name) } label: {
                                    if member.name == group.now { Label(member.name, systemImage: "checkmark") } else { Text(member.name) }
                                    Text(Format.delay(member.delay))
                                }
                            }
                        } label: {
                            Text(group.now ?? "—").lineLimit(1).truncationMode(.middle)
                        }
                        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).neutralControl()
                        .frame(maxWidth: 160, alignment: .trailing)
                        .help("切换节点")
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                }
            }
        }
    }
}

/// Why the core could not start, its last lines, and the way back.
private struct FailurePanel: View {
    @Environment(ProxyStore.self) private var store
    let message: String
    let log: [String]

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
                .frame(maxHeight: 180)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            HStack {
                SettingsLink { Text("打开设置…") }.neutralControl()
                Spacer()
                Button("重试") { store.start() }.primaryAction(.regular)
            }
        }
        .panel()
    }
}
