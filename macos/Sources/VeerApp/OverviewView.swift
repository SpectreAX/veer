import SwiftUI
import VeerCore
import VeerProxy

/// The dashboard: status and exit, traffic, services, connections and groups, as cards in a grid that
/// reflows with the window. Mode, switches and profile are in its toolbar.
struct OverviewView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.panelMotion) private var motion
    @State private var pageWidth = LatestWidth()
    /// The widths the cards' layout has at the two ends of the Agent panel's motion, while it moves.
    /// Between them the cards go from one arrangement to the other with the width itself.
    @State private var motionWidths: ClosedRange<CGFloat>?
    /// The motion as the content sees it: no wider than `maxContentWidth`, it may change by less.
    @State private var contentMotion: PanelMotion?

    /// The page's content is never wider than this; the cards' arrangement depends on it too.
    static let maxContentWidth: CGFloat = 1180

    nonisolated static func contentMotion(pageWidth: CGFloat, motion: PanelMotion) -> PanelMotion {
        PanelMotion(id: motion.id, widthChange: min(maxContentWidth, pageWidth + motion.widthChange) - min(maxContentWidth, pageWidth))
    }

    /// The cards' layout widths at the two ends of a motion starting with the page `pageWidth` wide:
    /// the content's width, no wider than `maxContentWidth`, less its margins.
    nonisolated static func motionWidths(pageWidth: CGFloat, motion: PanelMotion) -> ClosedRange<CGFloat> {
        let start = min(maxContentWidth, pageWidth) - 2 * Spacing.xl
        let end = min(maxContentWidth, pageWidth + motion.widthChange) - 2 * Spacing.xl
        return max(0, min(start, end))...max(0, start, end)
    }

    var body: some View {
        content
            .pageToolbar(.overview) {
                GlassSwitch(label: String(localized: "模式"), selection: Binding(get: { store.mode }, set: { store.setMode($0) }),
                            options: ProxyStore.Mode.allCases.map { .init(value: $0, title: $0.title) })
                    .disabled(!store.isRunning)
            } content: {
                OverviewToolbar()
            }
    }

    @ViewBuilder private var content: some View {
        if store.profiles.isEmpty {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "导入订阅链接、配置文件或节点分享链接后，Veer 会启动内核并按配置分流。"),
                      actionTitle: String(localized: "导入配置…")) { store.openImport() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if case .failed(let message, let log) = store.phase {
                        FailurePanel(message: message, log: log)
                    } else if let notice = store.notice {
                        StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true)
                    }
                    SuggestionCards()
                    OverviewCardsLayout(hasTraffic: true, motionWidths: motionWidths) {
                        StatusCard()
                        TrafficCard(direction: .upload)
                        TrafficCard(direction: .download)
                    }
                    OverviewCardsLayout(motionWidths: motionWidths) {
                        ServicesCard()
                        ConnectionsCard()
                    }
                    if store.isRunning { GroupsCard() }
                }
                .environment(\.panelMotion, contentMotion)
                .padding(Spacing.xl)
                .frame(maxWidth: Self.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth.value = $0 }
            .onChange(of: motion, initial: true) { _, motion in
                // A reversal part way is the same motion between the same two ends.
                if let motion {
                    if motionWidths == nil { motionWidths = Self.motionWidths(pageWidth: pageWidth.value, motion: motion) }
                } else {
                    motionWidths = nil
                }
                contentMotion = motion.map { Self.contentMotion(pageWidth: pageWidth.value, motion: $0) }
            }
            .task(id: store.isRunning) {
                guard store.isRunning else { return }
                store.checkExitIfNeeded()
                // Service latency now and once a minute while the dashboard is open.
                while !Task.isCancelled {
                    store.checkServices()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }
}

/// Page-width breakpoints, including the page's horizontal margins.
nonisolated enum OverviewArrangement: Equatable, Sendable {
    static let stackBelow: CGFloat = 720, stackPairsBelow: CGFloat = 460
    case columns, stackedRows, stackedPairs

    init(width: CGFloat) {
        if width < Self.stackPairsBelow { self = .stackedPairs } else if width < Self.stackBelow { self = .stackedRows } else { self = .columns }
    }

    var stacksRows: Bool { self != .columns }
    var stacksPairs: Bool { self == .stackedPairs }
}

/// Chooses and measures the card rows in the same layout pass as the real width proposal.
/// Geometry callbacks plus @State kept the previous arrangement alive for one narrower frame.
/// While the Agent panel moves, the cards go from the arrangement of one end to the other's with the
/// page's width, at every frame (`ArrangementBlend`): held in one arrangement and switched when the
/// motion ended, they grew to the full width and then jumped into columns.
nonisolated struct OverviewCardsLayout: Layout {
    var hasTraffic = false
    /// This layout's widths at the two ends of the Agent panel's motion, while it moves.
    var motionWidths: ClosedRange<CGFloat>?

    /// The frames last measured, and for which width: while the Agent panel moves this layout runs
    /// at every frame, and measuring the cards once per width instead of twice halves its share.
    struct Cache {
        var width: CGFloat?
        var motionWidths: ClosedRange<CGFloat>?
        var frames: [CGRect] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// The cards or what is in them changed: measure again.
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        let frames = frames(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews, cache: &cache)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    /// No alignment guides of its own. Left to the default, SwiftUI placed every card again just to
    /// find this layout's leading edge for the stack around it, at every frame of the panel's motion.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    /// The arrangement for a layout `width` wide: the page's content less its margins.
    static func arrangement(width: CGFloat) -> OverviewArrangement { OverviewArrangement(width: width + 2 * Spacing.xl) }

    /// Which cards share each row.
    static func rows(_ arrangement: OverviewArrangement, hasTraffic: Bool) -> [[Int]] {
        if hasTraffic {
            switch arrangement {
            case .columns: [[0, 1, 2]]
            case .stackedRows: [[0], [1, 2]]
            case .stackedPairs: [[0], [1], [2]]
            }
        } else {
            arrangement.stacksRows ? [[0], [1]] : [[0, 1]]
        }
    }

    /// Each card across in `arrangement` at `width`, by card, its height left to measure.
    static func columns(_ arrangement: OverviewArrangement, hasTraffic: Bool, width: CGFloat) -> [ArrangedItem] {
        var items: [Int: ArrangedItem] = [:]
        for (rowIndex, row) in rows(arrangement, hasTraffic: hasTraffic).enumerated() {
            let half = max(0, (width - Spacing.lg) / 2)
            let widths = row.count == 3 ? [half, max(0, (half - Spacing.lg) / 2), max(0, (half - Spacing.lg) / 2)]
                : Array(repeating: max(0, (width - CGFloat(row.count - 1) * Spacing.lg) / CGFloat(row.count)), count: row.count)
            var x: CGFloat = 0
            for (card, cardWidth) in zip(row, widths) {
                items[card] = ArrangedItem(x: x, width: cardWidth, row: rowIndex, height: 0)
                x += cardWidth + Spacing.lg
            }
        }
        return items.keys.sorted().compactMap { items[$0] }
    }

    /// `columns` with each card as tall as the tallest in its row.
    private func measured(_ arrangement: OverviewArrangement, width: CGFloat, subviews: Subviews) -> [ArrangedItem] {
        var items = Self.columns(arrangement, hasTraffic: hasTraffic, width: width)
        guard items.count <= subviews.count else { return [] }
        let heights = items.indices.map { subviews[$0].sizeThatFits(.init(width: items[$0].width, height: nil)).height }
        for index in items.indices {
            items[index].height = items.indices.filter { items[$0].row == items[index].row }.map { heights[$0] }.max() ?? 0
        }
        return items
    }

    private func frames(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGRect] {
        if cache.width == width, cache.motionWidths == motionWidths { return cache.frames }
        let frames: [CGRect]
        if let motionWidths, Self.arrangement(width: motionWidths.lowerBound) != Self.arrangement(width: motionWidths.upperBound) {
            frames = ArrangementBlend.frames(narrow: measured(Self.arrangement(width: motionWidths.lowerBound), width: width, subviews: subviews),
                                             wide: measured(Self.arrangement(width: motionWidths.upperBound), width: width, subviews: subviews),
                                             spacing: Spacing.lg, progress: ArrangementBlend.progress(width: width, range: motionWidths))
        } else {
            let items = measured(Self.arrangement(width: width), width: width, subviews: subviews)
            frames = ArrangementBlend.frames(narrow: items, wide: items, spacing: Spacing.lg, progress: 1)
        }
        cache = Cache(width: width, motionWidths: motionWidths, frames: frames)
        return frames
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
            // The title stays on one line; without room beside it the accessory goes below. Just
            // over the 720 pt arrangement, as the page passes through it with the Agent panel or a
            // window resize, "Upload" otherwise broke into "Up-" and "load".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    titleLabel
                    Spacer(minLength: 0)
                    accessory().fixedSize()
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    titleLabel
                    accessory()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }

    private var titleLabel: some View {
        Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }
}

/// Running or not, where traffic leaves, for how long, and the one big start/stop button.
private struct StatusCard: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card(String(localized: "状态"), symbol: "waveform.path.ecg") {
            StatusBadge(kind: store.phase.kind, text: store.phase.title, compact: true)
        } content: {
            // The whole width for the address, which matters most here, beside the Agent panel too.
            exit
            // Keep one glass button outside the text's fitting alternatives. Recreating it as
            // ViewThatFits changed candidates let its layer animate across neighbouring cards.
            HStack(alignment: .center, spacing: Spacing.lg) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.xl) { runTime; network }
                    VStack(alignment: .leading, spacing: Spacing.sm) { runTime; network }
                }
                Spacer(minLength: 0)
                // After a failure the panel above has Try Again, the one primary action.
                if !store.phase.isFailed { startButton }
            }
            // Full width keeps the local address and its port readable beside the Agent panel.
            localAddress
            reach
        }
    }

    /// Whether traffic reaches Veer at all, in words, as the toolbar's switches say it only in a fill.
    @ViewBuilder private var reach: some View {
        let tun = String(localized: "TUN：\(store.tunStatus)")
        switch TrafficReach(running: store.isRunning, tunActive: store.tunActive, systemProxyOn: store.systemProxyOn,
                            systemProxyRemembered: store.systemProxyRemembered) {
        case .bypassed:
            StatusBadge(kind: .warning, text: String(localized: "系统代理和 TUN 都没生效，流量不经过 Veer"))
                .fixedSize(horizontal: false, vertical: true)
        case .tun:
            reachLine(String(localized: "TUN 已接管全部流量"))
        case .systemProxy:
            reachLine(String(localized: "系统代理已打开，端口 \(String(store.proxyPort))"), tun)
        case .systemProxyComing:
            reachLine(String(localized: "正在打开系统代理"), tun)
        case .stopped(let proxyOnStart):
            reachLine(proxyOnStart ? String(localized: "启动后打开系统代理") : String(localized: "系统代理已关闭"), tun)
        }
    }

    /// On one line, or a line each when that would break in the middle of one.
    private func reachLine(_ parts: String...) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: parts.joined(separator: " · ")).lineLimit(1)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(parts, id: \.self) { Text(verbatim: $0) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var runTime: some View {
        LabeledValue(String(localized: "运行时间")) {
            if let since = store.runningSince, store.isRunning {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(verbatim: Format.duration(since: since, now: context.date)).monospacedDigit()
                }
            } else { Text(verbatim: "—") }
        }
    }

    private var network: some View {
        LabeledValue(String(localized: "网络")) {
            Text(store.exit?.organization ?? "—").lineLimit(1).truncationMode(.tail).help(store.exit?.organization ?? "")
        }
    }

    /// What a device on the local network connects to.
    private var localAddress: some View {
        LabeledValue(String(localized: "局域网")) {
            if !store.settings.allowLAN {
                Text("仅本机可用").lineLimit(1)
            } else if !store.isRunning {
                Text("启动后生效").lineLimit(1)
            } else if let address = ProxyStore.localAddress {
                Text(verbatim: "\(address):\(store.proxyPort)").lineLimit(1).textSelection(.enabled)
            } else {
                Text(verbatim: "—")
            }
        }
    }

    @ViewBuilder private var exit: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            if store.isRunning, let exit = store.exit, !exit.ip.isEmpty {
                // The country gives way first: the flag says it too, and the address is the point.
                ViewThatFits(in: .horizontal) {
                    address(of: exit, country: exit.country)
                    address(of: exit, country: nil)
                }
            } else if store.isRunning, store.exit == .unknown {
                Text("无法检测出口").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } else if store.isRunning, store.showExitIP {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                // Short, on one line as the IP that replaces it is: the narrowest window has room for
                // little more, and the card's title says what this is about.
                Text("正在检测…").font(.title3).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(store.activeProfile?.name ?? "").font(.title3.weight(.semibold)).lineLimit(1)
            }
            // Not while a check is under way.
            if store.isRunning, store.exit != nil {
                Button { store.recheckExit() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("重新检测出口")
                    .accessibilityLabel(String(localized: "重新检测出口"))
            }
        }
    }

    private func address(of exit: ExitInfo, country: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            if !exit.flag.isEmpty { Text(exit.flag).font(.title) }
            Text(exit.ip).font(.system(.title, design: .rounded).weight(.semibold)).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let country { Tag(text: country).fixedSize() }
        }
    }

    private var startButton: some View {
        Button { store.isRunning ? store.stop() : store.start() } label: {
            Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                .font(.title.weight(.semibold))
                .frame(width: 64, height: 64)
        }
        .buttonBorderShape(.circle)
        // Prominent for the likely action, starting; once the core runs, Stop is a secondary action,
        // as in the toolbar, since it cuts every connection. Both keep the same size and place. The
        // two system styles are two buttons to SwiftUI, so the change is a crossfade of the whole
        // button (a fade, which Reduce Motion keeps), not a symbol replacing itself in place.
        .modifier(StartStopStyle(prominent: !store.isRunning))
        .animation(Motion.quick, value: store.isRunning)
        .overlay { CoreStateRing(phase: store.phase) }
        .disabled(store.phase == .starting || store.activeProfile == nil)
        .help(store.isRunning ? String(localized: "停止内核（⌘R）") : String(localized: "启动内核（⌘R）"))
        .accessibilityLabel(store.phase == .starting ? String(localized: "正在启动") : store.isRunning ? String(localized: "停止") : String(localized: "启动"))
    }
}

/// The big button's style: the page's primary action while the core can be started, a secondary one
/// while it runs.
private struct StartStopStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent { content.primaryAction() } else { content.secondaryAction().controlSize(.large) }
    }
}

/// Around the big button, what the core is doing: a ring that turns while it starts, and one ripple
/// when it has started or stopped. With Reduce Motion, a steady ring and no ripple; either way the
/// status above says it in words, and VoiceOver hears it on this page.
private struct CoreStateRing: View {
    let phase: ProxyStore.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples = 0
    @State private var rippleColor = Color.veerAccent

    private static let lineWidth: CGFloat = 3
    private static let turn: TimeInterval = 1.1

    private enum Ripple: CaseIterable {
        case idle, shown, gone

        var opacity: Double { self == .shown ? 0.7 : 0 }
        var scale: CGFloat { self == .gone ? 1.4 : 1 }
    }

    var body: some View {
        ZStack {
            if phase == .starting { startingRing.padding(-Spacing.xs) }
            if !reduceMotion {
                Circle()
                    .stroke(rippleColor, lineWidth: Self.lineWidth)
                    .phaseAnimator(Ripple.allCases, trigger: ripples) { circle, ripple in
                        circle.scaleEffect(ripple.scale).opacity(ripple.opacity)
                    } animation: { ripple in
                        ripple == .gone ? Motion.ripple : Motion.step
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: phase) { old, new in
            AccessibilityNotification.Announcement(new.title).post()
            // Not when a failure ends a start: the panel above the cards says so.
            guard new == .running || (new == .stopped && old == .running) else { return }
            rippleColor = new == .running ? Color.veerAccent : Color.secondary
            ripples += 1
        }
    }

    @ViewBuilder private var startingRing: some View {
        if reduceMotion {
            Circle().stroke(Color.veerAccent.opacity(0.5), lineWidth: Self.lineWidth)
        } else {
            TimelineView(.animation) { context in
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.veerAccent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.turn) / Self.turn * 360))
            }
        }
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
            // Whole: the row shares its width out evenly, which broke "Network" in the narrowest window.
            Text(title).font(.caption).foregroundStyle(.secondary).fixedSize()
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

/// The system proxy, TUN and local network switches: what the proxy reaches, together in one group.
private struct OverviewToolbar: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        ToolbarToggle(title: String(localized: "系统代理"), symbol: "network", isOn: store.systemProxyOn,
                      help: String(localized: "系统代理：\(proxyStatus)")) {
            store.setSystemProxy(!store.systemProxyOn)
        }
        .disabled(!store.isRunning)
        ToolbarToggle(title: String(localized: "TUN"), symbol: tunWithoutEffect ? "exclamationmark.shield" : "shield.lefthalf.filled",
                      isOn: store.settings.tun && !tunWithoutEffect, help: String(localized: "TUN：\(store.tunStatus)"), value: store.tunStatus) {
            store.setTUN(!store.settings.tun)
        }
        ToolbarToggle(title: String(localized: "允许局域网设备连接"), symbol: "rectangle.connected.to.line.below", isOn: store.settings.allowLAN,
                      help: store.settings.allowLAN ? String(localized: "允许局域网设备连接") : String(localized: "仅本机可用")) {
            store.settings.allowLAN.toggle()
        }
    }

    private var proxyStatus: String {
        store.tunActive ? String(localized: "TUN 已接管全部流量") : String(localized: "端口 \(String(store.proxyPort))")
    }

    private var tunWithoutEffect: Bool { store.settings.tun && store.isRunning && !store.tunActive }
}

private extension ProxyStore {
    var tunStatus: String {
        if tunActive { return String(localized: "运行中") }
        if !settings.tun { return String(localized: "已关闭") }
        return isRunning ? String(localized: "未生效，已改用系统代理") : String(localized: "启动后生效")
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
                        // The symbols differ in width, which would leave the names out of line.
                        Label {
                            Text(service.name)
                        } icon: {
                            Image(systemName: service.symbol).frame(width: Spacing.lg + Spacing.xs)
                        }
                        .font(.callout).lineLimit(1)
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

    var body: some View {
        Card(String(localized: "overview.groups", defaultValue: "策略组"), symbol: "square.stack.3d.up") {
            Button { store.page = .proxies } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("打开代理页")
                .accessibilityLabel(String(localized: "打开代理页"))
        } content: {
            BlendedGrid(minimum: 240, spacing: Spacing.md, rowSpacing: Spacing.sm) {
                ForEach(store.groups.filter(\.isSelectable)) { group in
                    HStack(spacing: Spacing.sm) {
                        Text(group.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.sm)
                        GroupQuickSwitchMenu(group: group, title: group.now ?? "—", font: .body, truncation: .byTruncatingMiddle)
                            .frame(maxWidth: 160, alignment: .trailing)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                }
            }
        }
    }
}
