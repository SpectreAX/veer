import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// What one test found, with what it was checked against.
struct RouteTestResult: Equatable {
    let trace: RouteTrace
    let inputs: RouteTestSource.Inputs
    /// The domain's address could not be found, so IP rules stayed undecided.
    let unresolved: Bool
}

/// Which rule a destination hits in the config the core runs, and where that sends it. Veer checks
/// every rule in order on this Mac without making a connection, and names each rule it cannot decide
/// here (the app that connects, a rule set it cannot read) instead of guessing past it.
struct RouteTestView: View {
    @Environment(ProxyStore.self) private var store
    @State private var host = ""
    @State private var port = "443"
    @State private var network = RouteQuery.Network.tcp
    @State private var result: RouteTestResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var showsChecked = false

    private static let hostFieldWidth: CGFloat = 220
    private static let portFieldWidth: CGFloat = 64
    /// The resolver for IP rules: the one the Agent's domain checks use.
    static let resolver = DNSServer.presets[1].server
    static var resolverTitle: String { String(localized: "阿里 DoH") }

    private var testing: Bool { task != nil }

    var body: some View {
        if store.activeProfile == nil {
            StateView(symbol: Page.route.symbol, title: String(localized: "还没有配置"),
                      message: String(localized: "导入一个配置后，可以在这里测试它的分流。"))
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.sm) {
                        hostField.frame(minWidth: Self.hostFieldWidth)
                        testControls
                    }
                    VStack(alignment: .trailing, spacing: Spacing.sm) {
                        hostField
                        HStack(spacing: Spacing.sm) { testControls }
                    }
                }
                Text(String(localized: "用当前配置（含“我的分流”和 Veer 加在最前面的规则）在本机逐条判断，不发出连接。需要按 IP 判断时，域名通过\(Self.resolverTitle)解析。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let modeNote { StatusBadge(kind: .info, text: modeNote, compact: true).fixedSize(horizontal: false, vertical: true) }
                if let error { StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true) }
                if let result {
                RouteTestResultView(result: result, showsChecked: $showsChecked)
                    // The last result stays while a new test runs, dimmed so it is not read as the new one.
                    .opacity(testing ? 0.5 : 1)
            }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear(perform: takeRequest)
        .onChange(of: store.routeTestRequest) { _, _ in takeRequest() }
        .onDisappear { task?.cancel() }
    }

    private var hostField: some View {
        TextField(String(localized: "域名、IP 或网址"), text: $host, prompt: Text(verbatim: "www.example.com"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(test)
    }

    @ViewBuilder private var testControls: some View {
        TextField(String(localized: "端口"), text: $port, prompt: Text(verbatim: "443"))
            .textFieldStyle(.roundedBorder)
            .frame(width: Self.portFieldWidth)
            .onSubmit(test)
            .help(String(localized: "目标端口"))
            .accessibilityLabel(String(localized: "端口"))
        SegmentedControl(label: String(localized: "网络"), selection: $network,
                         options: RouteQuery.Network.allCases.map { .init(value: $0, title: $0.rawValue) })
            .fixedSize()
        if testing {
            ProgressView().controlSize(.small)
            Button(String(localized: "取消")) { task?.cancel() }.secondaryAction().keyboardShortcut(.cancelAction)
        } else {
            Button(String(localized: "测试"), action: test).primaryAction(.regular).keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Rules decide nothing in the global and direct modes.
    private var modeNote: String? {
        switch store.mode {
        case .rule: nil
        case .global: String(localized: "现在是全局模式：所有流量都走 GLOBAL 策略组，不看规则。下面是规则模式下的结果。")
        case .direct: String(localized: "现在是直连模式：所有流量都直连，不看规则。下面是规则模式下的结果。")
        }
    }

    private func takeRequest() {
        guard let request = store.routeTestRequest else { return }
        store.routeTestRequest = nil
        host = request.host
        port = String(request.port)
        network = request.network
        task?.cancel()
        task = nil
        test()
    }

    private func test() {
        guard !testing else { return }
        guard let query = RouteQuery(host, port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0, network: network) else {
            error = String(localized: "请输入域名、IP 或网址，端口为 1 到 65535。")
            return
        }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                let source = try await store.routeTestSource()
                var data = source.data
                var trace = await Task.detached { [data] in RouteTracer.trace(query, rules: source.rules, data: data) }.value
                var unresolved = false
                if trace.needsAddress {
                    let answers = try? await DNSResolver().lookup(query.host, type: .a, server: Self.resolver).answers.compactMap(\.address)
                    try Task.checkCancellation()
                    if let address = answers?.first {
                        data.address = address.description
                        trace = await Task.detached { [data] in RouteTracer.trace(query, rules: source.rules, data: data) }.value
                    } else {
                        unresolved = true
                    }
                }
                try Task.checkCancellation()
                showsChecked = false
                result = RouteTestResult(trace: trace, inputs: source.inputs, unresolved: unresolved)
            } catch is CancellationError {
                error = nil
            } catch {
                result = nil
                self.error = (error as? EditorError)?.message ?? store.message(for: error)
            }
        }
    }
}

/// The hit and where it goes, the rules before it that could not be decided, and every rule checked.
struct RouteTestResultView: View {
    @Environment(ProxyStore.self) private var store
    let result: RouteTestResult
    @Binding var showsChecked: Bool

    private var trace: RouteTrace { result.trace }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    summary
                    Spacer(minLength: Spacing.sm)
                    copyButton
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    summary
                    copyButton
                }
            }
            if let hit = trace.hit {
                Text(verbatim: hit.rule).font(Typography.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                exit(hit)
                if !hit.conditions.isEmpty { conditions(hit.conditions) }
            } else {
                Text("没有规则匹配，内核会直连。").font(.callout).foregroundStyle(.secondary)
            }
            addressNote
            if !trace.unknowns.isEmpty { unknownSection }
            checkedSection
            Text(verbatim: inputsNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private var summary: some View {
        HStack(spacing: Spacing.sm) {
            if let hit = trace.hit {
                StatusBadge(kind: trace.certain ? .success : .warning,
                            text: trace.certain ? String(localized: "命中第 \(hit.index + 1) 条") : String(localized: "可能命中第 \(hit.index + 1) 条"))
            } else {
                StatusBadge(kind: .neutral, text: String(localized: "没有命中"))
            }
            Text(verbatim: "\(trace.query.host) · \(trace.query.port) · \(trace.query.network.rawValue)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var copyButton: some View {
        Button(String(localized: "复制结果")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RouteTestText.summary(result, exit: trace.hit?.target.map(store.exitChain(from:))), forType: .string)
        }
        .secondaryAction().controlSize(.small)
        .help(String(localized: "复制测试结果"))
    }

    @ViewBuilder private func exit(_ hit: RouteStep) -> some View {
        if let target = hit.target {
            let chain = store.exitChain(from: target)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text("出口").font(.callout).foregroundStyle(.secondary)
                    Text(verbatim: chain.joined(separator: " → ")).font(.callout.weight(.semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !store.isRunning, chain.count == 1, !["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(target) {
                    Text("内核没有运行，看不到策略组现在选的节点。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var addressNote: some View {
        if let address = trace.address {
            Text(String(localized: "按 IP 判断的规则用 \(address)（\(RouteTestView.resolverTitle)的结果）。内核用自己的 DNS 设置解析，得到的地址可能不同。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if result.unresolved {
            StatusBadge(kind: .warning, text: String(localized: "没能解析这个域名，按 IP 判断的规则没有判断。"), compact: true)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unknownSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "本机无法判断的规则（\(trace.unknowns.count)）")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(trace.hit == nil
                 ? String(localized: "其中任何一条实际匹配时，流量会走它。")
                 : String(localized: "它们排在命中的规则前面：其中任何一条实际匹配时，流量会先走它。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(trace.unknowns) { RouteStepRow(step: $0) }
        }
    }

    private var checkedSection: some View {
        let before = trace.steps.count - (trace.hit == nil ? 0 : 1)
        return DisclosureGroup(isExpanded: $showsChecked) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(trace.steps) { RouteStepRow(step: $0) }
            }
            .padding(.top, Spacing.xs)
        } label: {
            Text(trace.hit == nil
                 ? String(localized: "检查了 \(trace.steps.count) 条规则，都没有命中")
                 : String(localized: "检查了 \(trace.steps.count) 条规则，前面 \(before) 条没有命中"))
                .font(.callout)
        }
    }

    private func conditions(_ steps: [RouteStep]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { RouteStepRow(step: $0, isCondition: true) }
        }
        .padding(.leading, Spacing.md)
    }

    private var inputsNote: String {
        let inputs = result.inputs
        var parts = [
            inputs.geosite.map { String(localized: "GEOSITE 用 \($0)") } ?? String(localized: "本机没有 GeoSite 数据"),
            inputs.geoip.map { String(localized: "GEOIP 用 \($0)") } ?? String(localized: "本机没有 GeoIP 数据"),
        ]
        if !inputs.readable.isEmpty || !inputs.unreadable.isEmpty {
            parts.append(inputs.unreadable.isEmpty
                ? String(localized: "读取了 \(inputs.readable.count) 个规则集")
                : String(localized: "读取了 \(inputs.readable.count) 个规则集，\(inputs.unreadable.count) 个无法读取（MRS 格式或还没下载）"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One rule or condition with what it gave, and why when it could not be decided.
struct RouteStepRow: View {
    let step: RouteStep
    var isCondition = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: Self.symbol(step.outcome)).foregroundStyle(Self.color(step.outcome)).accessibilityHidden(true)
            if !isCondition {
                Text(verbatim: "\(step.index + 1)").font(Typography.codeSmall).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: step.rule).font(Typography.codeSmall).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(RouteTestText.outcome(step.outcome)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !step.conditions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) { ForEach(step.conditions) { RouteStepRow(step: $0, isCondition: true) } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ outcome: RouteOutcome) -> String {
        switch outcome {
        case .matched: "checkmark.circle.fill"
        case .notMatched: "minus.circle"
        case .unknown: "questionmark.circle.fill"
        }
    }

    static func color(_ outcome: RouteOutcome) -> Color {
        switch outcome {
        case .matched: .statusSuccess
        case .notMatched: .secondary
        case .unknown: .statusWarning
        }
    }
}

/// The page's words for outcomes, and the copied summary.
enum RouteTestText {
    static func outcome(_ outcome: RouteOutcome) -> String {
        switch outcome {
        case .matched: String(localized: "匹配")
        case .notMatched: String(localized: "不匹配")
        case .unknown(let why): String(localized: "无法判断：\(reason(why))")
        }
    }

    static func reason(_ reason: RouteUnknown) -> String {
        switch reason {
        case .address: String(localized: "需要域名的 IP 地址")
        case .geosite: String(localized: "本机没有可用的 GeoSite 数据")
        case .geoip: String(localized: "本机没有可用的 GeoIP 数据")
        case .ruleSet(let name): String(localized: "规则集“\(name)”的内容无法读取")
        case .connection(let type): String(localized: "取决于发起连接的应用或来源（\(type)）")
        case .unsupported(let type): String(localized: "Veer 不判断 \(type) 规则")
        }
    }

    static func summary(_ result: RouteTestResult, exit: [String]?) -> String {
        let trace = result.trace
        var lines = ["\(trace.query.host) · \(trace.query.port) · \(trace.query.network.rawValue)"]
        if let hit = trace.hit {
            lines.append((trace.certain ? String(localized: "命中第 \(hit.index + 1) 条") : String(localized: "可能命中第 \(hit.index + 1) 条")) + "：\(hit.rule)")
            if let exit { lines.append(String(localized: "出口") + "：" + exit.joined(separator: " → ")) }
        } else {
            lines.append(String(localized: "没有规则匹配，内核会直连。"))
        }
        if let address = trace.address { lines.append("IP: \(address)") }
        for step in trace.unknowns {
            if let why = step.outcome.unknownReason { lines.append("? \(step.index + 1). \(step.rule) — \(reason(why))") }
        }
        return lines.joined(separator: "\n")
    }
}

private extension RouteOutcome {
    var unknownReason: RouteUnknown? { if case .unknown(let reason) = self { reason } else { nil } }
}
