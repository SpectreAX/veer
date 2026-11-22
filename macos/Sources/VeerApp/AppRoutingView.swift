import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeerCore
import VeerProxy

/// The Proxies page's App Routing view: which apps go where, for the active profile, in priority order.
struct AppRoutingView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(\.undoManager) private var undoManager
    let query: String
    @State private var rules: [AppRule] = []
    @State private var selection: AppRule.ID?
    @State private var targets: (groups: [String], nodes: [String]) = ([], [])
    @State private var adding = false
    @State private var addingDomain: AppRule?
    @State private var error: String?
    @State private var working = false
    @State private var detailContentHeight: CGFloat = 240
    @State private var detailFits = true
    @State private var showingDetail = false
    static let minListHeight: CGFloat = 150
    static let minDetailHeight: CGFloat = 96
    static let maxDetailHeight: CGFloat = 240

    private var selectedRule: AppRule? { rules.first { $0.id == selection } }

    /// `reportHeight`: the inline panel says how tall its content is, so the layout can make room.
    private func detail(for rule: AppRule, reportHeight: Bool) -> some View {
        ScrollView {
            AppRuleDetail(rule: rule, report: store.appRoutingReport, targets: targets,
                          update: { update($0) }, addDomain: { addingDomain = rule },
                          removeDomain: { domain in update(rule.removingDomain(domain)) })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if reportHeight { detailContentHeight = $0 } }
        }
    }

    private var shown: [AppRule] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return rules }
        return rules.filter { rule in
            rule.app.name.lowercased().contains(text) || rule.app.root.lowercased().contains(text) || (rule.app.bundleID?.lowercased().contains(text) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rules.isEmpty {
                StateView(symbol: "app.badge.checkmark", title: String(localized: "还没有应用规则"),
                          message: String(localized: "让选定的应用走指定的出口、始终直连或不能联网。没有规则的应用按配置的规则走。"),
                          actionTitle: String(localized: "添加应用…")) { adding = true }
            } else {
                // The rules keep a few rows; the selected one's details take what is left, up to their
                // own height, and move to a sheet (`showingDetail`) when too little is left.
                GeometryReader { geometry in
                    let detailHeight = min(detailContentHeight, Self.maxDetailHeight, geometry.size.height - Self.minListHeight)
                    let fits = detailHeight >= Self.minDetailHeight
                    VStack(spacing: 0) {
                        list
                        if let rule = selectedRule, fits {
                            Divider()
                            detail(for: rule, reportHeight: true).frame(height: detailHeight)
                        }
                    }
                    .onChange(of: fits, initial: true) { detailFits = fits }
                }
            }
            Divider()
            bottomBar
        }
        .task(id: store.activeProfileID) { await reload() }
        .onChange(of: store.appRulesRevision) { Task { await reload() } }
        .onAppear {
            store.loadApps()
            store.watchConnections(true)
        }
        .onDisappear { store.watchConnections(false) }
        .sheet(isPresented: $adding) {
            AppPickerSheet(existing: Set(rules.map(\.app.root)), targets: targets) { app, target in
                update(AppRule(app: app, target: target))
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let rule = selectedRule {
                VStack(spacing: 0) {
                    detail(for: rule, reportHeight: false)
                    Divider()
                    HStack {
                        Spacer()
                        Button("完成") { showingDetail = false }.keyboardShortcut(.defaultAction)
                    }
                    .padding(Spacing.md)
                }
                .frame(width: 520, height: 420)
            }
        }
        .sheet(item: $addingDomain) { rule in
            DomainRouteSheet(app: rule.app, targets: targets) { route in update(rule.addingDomain(route)) }
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text("应用分流").font(.headline)
                if let profile = store.activeProfile {
                    Text("保存在“\(profile.name)”").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }
            AppRoutingGateNote()
            if let error { StatusBadge(kind: .failure, text: error).lineLimit(4).textSelection(.enabled) }
            if let overruled = store.appRoutingReport?.profileProcessRules, !overruled.isEmpty {
                StatusBadge(kind: .info, text: String(localized: "配置自带 \(overruled.count) 条按进程的规则，应用规则在它们之前，同一应用以这里为准。"), compact: true)
                    .help(overruled.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, rule in
                AppRuleRow(rule: rule, order: (rules.firstIndex(of: rule) ?? index) + 1, report: store.appRoutingReport, targets: targets,
                           connections: store.connectionCount(of: rule.app), update: { update($0) })
                    .tag(rule.id)
                    .contextMenu { menu(for: rule) }
                    // Drag is not available to VoiceOver or the keyboard; these and ⌥↑ / ⌥↓ are.
                    .accessibilityAction(named: String(localized: "上移")) { move(rule.id, by: -1) }
                    .accessibilityAction(named: String(localized: "下移")) { move(rule.id, by: 1) }
            }
            .onMove(perform: query.isEmpty ? { move($0, to: $1) } : nil)
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), let selection else { return .ignored }
            move(selection, by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), let selection else { return .ignored }
            move(selection, by: 1)
            return .handled
        }
        .onDeleteCommand { if let selection { remove(selection) } }
        .onAppear(perform: focusRequested)
        .onChange(of: store.appRoutingFocus) { focusRequested() }
    }

    @ViewBuilder private func menu(for rule: AppRule) -> some View {
        Button(rule.enabled ? String(localized: "停用这条规则") : String(localized: "启用这条规则")) { update(rule.with(enabled: !rule.enabled)) }
        Button("添加域名例外…") { addingDomain = rule }
        Divider()
        Button("上移") { move(rule.id, by: -1) }.disabled(rules.first?.id == rule.id)
        Button("下移") { move(rule.id, by: 1) }.disabled(rules.last?.id == rule.id)
        Divider()
        Button("重新连接这个应用的连接") { Task { await store.reconnect(rule.app) } }.disabled(!store.isRunning)
        Button(String(localized: "问 Agent：“\(rule.app.name)”怎么走？")) { agent.open(asking: String(localized: "“\(rule.app.name)”的流量现在怎么走？")) }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rule.app.root)]) }
        Divider()
        Button("移除规则", role: .destructive) { remove(rule.id) }
    }

    private var bottomBar: some View {
        HStack(spacing: Spacing.sm) {
            // Beside the Agent panel the page can be too narrow for the labels: the hint goes first,
            // then the words, leaving the list's usual + and − buttons rather than cut-off labels.
            let hint = String(localized: "排在前面的先匹配；拖动，或选中后按 ⌥↑ / ⌥↓ 调整顺序。")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    listButtons
                    Spacer(minLength: Spacing.sm)
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: Spacing.sm) {
                    listButtons
                    Spacer(minLength: 0)
                }
                HStack(spacing: Spacing.sm) {
                    listButtons.labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                }
            }
            .help(hint)
            Button { store.loadApps(rescan: true) } label: { Label("重新扫描应用", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly)
                .disabled(store.scanningApps)
                .help("重新扫描“应用程序”文件夹")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder private var listButtons: some View {
        Button { adding = true } label: { Label("添加应用…", systemImage: "plus") }
            .help("添加应用或命令行工具")
        Button { if let selection { remove(selection) } } label: { Label("移除规则", systemImage: "minus") }
            .disabled(selection == nil)
            .help("移除选中的规则（可以撤销）")
        if !detailFits {
            Button { showingDetail = true } label: { Label("详情…", systemImage: "info.circle") }
                .disabled(selectedRule == nil)
                .help("窗口太矮，选中规则的详情在单独的面板里显示")
        }
    }

    // MARK: Changes

    private func reload() async {
        guard let id = store.activeProfileID else { rules = []; return }
        rules = store.appRules(of: id)
        if store.effective == nil { _ = try? await store.effectiveTextInBackground(of: id) }
        targets = await store.appRouteTargets()
    }

    private func focusRequested() {
        guard let focus = store.appRoutingFocus else { return }
        selection = rules.first { $0.app.id == focus }?.id
        store.appRoutingFocus = nil
    }

    /// Adds or replaces one rule.
    private func update(_ rule: AppRule) {
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule } else { next.append(rule) }
        commit(next, select: rule.id, actionName: String(localized: "修改应用规则"))
    }

    private func remove(_ id: AppRule.ID) {
        commit(rules.filter { $0.id != id }, select: nil, actionName: String(localized: "移除应用规则"))
    }

    private func move(_ offsets: IndexSet, to destination: Int) {
        var next = rules
        next.move(fromOffsets: offsets, toOffset: destination)
        commit(next, select: selection, actionName: String(localized: "调整应用规则顺序"))
    }

    private func move(_ id: AppRule.ID, by step: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + step) else { return }
        var next = rules
        next.swapAt(index, index + step)
        commit(next, select: id, actionName: String(localized: "调整应用规则顺序"))
    }

    /// Saves through the store, which checks the config and rolls back a refusal; undo puts the
    /// rules back the same way.
    private func commit(_ next: [AppRule], select: AppRule.ID?, actionName: String) {
        guard let id = store.activeProfileID else { return }
        let previous = rules
        rules = next
        selection = select
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await store.setAppRules(next, for: id)
                registerUndo(restoring: previous, profile: id, actionName: actionName)
            } catch {
                rules = previous
                self.error = store.message(for: error)
            }
        }
    }

    private func registerUndo(restoring previous: [AppRule], profile id: UUID, actionName: String) {
        store.registerAppRulesUndo(restoring: previous, then: rules, profile: id, actionName: actionName, manager: undoManager)
    }
}

extension AppRule {
    func with(enabled: Bool) -> AppRule {
        var copy = self
        copy.enabled = enabled
        return copy
    }

    func with(target: Target) -> AppRule {
        var copy = self
        copy.target = target
        return copy
    }

    func addingDomain(_ route: DomainRoute) -> AppRule {
        var copy = self
        copy.domains.append(route)
        return copy
    }

    func removingDomain(_ id: DomainRoute.ID) -> AppRule {
        var copy = self
        copy.domains.removeAll { $0.id == id }
        return copy
    }
}

/// Why rules would not route now, with the way to change that.
struct AppRoutingGateNote: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        switch store.appRoutingGate {
        case .inEffect:
            StatusBadge(kind: .success, text: String(localized: "规则模式，应用规则正在生效。"), compact: true)
        case .coreStopped:
            StatusBadge(kind: .neutral, text: String(localized: "内核没有运行：规则已保存，启动后生效。"), compact: true)
        case .notRuleMode(let mode):
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: .warning, text: String(localized: "现在是\(mode.title)模式，所有流量走同一处，应用规则不起作用。"), compact: true)
                Button("切换到规则模式") { store.setMode(.rule) }.controlSize(.small)
            }
        case .processMatchingOff:
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: .warning, text: String(localized: "“按进程匹配”已关闭，内核不知道连接来自哪个应用，应用规则不起作用。"), compact: true)
                Button("打开按进程匹配") { store.settings.processMatching = true }.controlSize(.small)
            }
        }
    }
}

/// The app's own icon, as Finder shows it. `NSWorkspace` is the only source of it; SwiftUI has none.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 24
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func icon(_ path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// The exits a rule can name, as a menu: the profile's own rules, direct, blocked, then groups and nodes.
struct AppTargetPicker: View {
    let title: String
    @Binding var target: AppRule.Target
    let targets: (groups: [String], nodes: [String])
    var allowsFollowProfile = true

    var body: some View {
        Picker(title, selection: $target) {
            if allowsFollowProfile { Text("按配置的规则（默认）").tag(AppRule.Target.followProfile) }
            Text("直连").tag(AppRule.Target.direct)
            Text("阻止联网").tag(AppRule.Target.reject)
            if !targets.groups.isEmpty {
                Section("策略组") {
                    ForEach(targets.groups.filter { !ConfigDocument.builtinPolicies.contains($0) }.uniqued(), id: \.self) {
                        Text($0).tag(AppRule.Target.policy($0))
                    }
                }
            }
            if !targets.nodes.isEmpty {
                Section("节点") {
                    ForEach(targets.nodes.uniqued(), id: \.self) { Text($0).tag(AppRule.Target.policy($0)) }
                }
            }
            if case .policy(let name) = target, !targets.groups.contains(name), !targets.nodes.contains(name) {
                Text("\(name)（已不存在）").tag(target)
            }
        }
        .neutralControl()
    }
}

extension AppRule.Target {
    var title: String {
        switch self {
        case .followProfile: String(localized: "按配置的规则")
        case .direct: String(localized: "直连")
        case .reject: String(localized: "阻止联网")
        case .policy(let name): name
        }
    }
}

/// One rule in the list: its place, the app, what happens to it now, its exit and a switch.
struct AppRuleRow: View {
    @Environment(ProxyStore.self) private var store
    let rule: AppRule
    let order: Int
    let report: AppRuleBuilder.Report?
    let targets: (groups: [String], nodes: [String])
    let connections: Int
    let update: (AppRule) -> Void

    /// The place, icon, a 160-point name column, the exit menu at 140 and the switch, in one line.
    static let oneLineWidth: CGFloat = 440
    private static let placeWidth: CGFloat = 18
    private static let iconSize: CGFloat = 24

    var body: some View {
        // The page can be as narrow as `AgentPanelColumn.minimumPageWidth` beside the Agent panel;
        // there the exit menu and switch go under the name rather than past the row's edge.
        SteadyChoice(requiredWidth: Self.oneLineWidth) {
            HStack(spacing: Spacing.md) {
                place
                identity.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                // A menu picker is as wide as its widest item, and node names run long: held to a
                // column so the app's name and status keep the room.
                exit.frame(minWidth: 140, maxWidth: 280)
                enabled
            }
            .frame(idealWidth: Self.oneLineWidth)
        } narrow: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.md) {
                    place
                    identity.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Spacing.md) {
                    exit.frame(maxWidth: 280)
                    Spacer(minLength: 0)
                    enabled
                }
                .padding(.leading, Self.placeWidth + Self.iconSize + 2 * Spacing.md)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
    }

    private var place: some View {
        HStack(spacing: Spacing.md) {
            Text("\(order)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: Self.placeWidth, alignment: .trailing)
                .accessibilityLabel(Text("第 \(order) 条"))
            AppIcon(path: rule.app.root, size: Self.iconSize)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Text(rule.app.name).lineLimit(1)
                if !rule.domains.isEmpty {
                    Tag(text: String(localized: "域名例外 \(rule.domains.count)"))
                }
            }
            AppRuleStatusLabel(rule: rule, report: report, connections: connections).lineLimit(2)
        }
    }

    private var exit: some View {
        AppTargetPicker(title: String(localized: "出口"),
                        target: Binding(get: { rule.target }, set: { update(rule.with(target: $0)) }), targets: targets)
            .labelsHidden()
            .help("\(rule.app.name) 的流量走哪里")
    }

    private var enabled: some View {
        Toggle("启用", isOn: Binding(get: { rule.enabled }, set: { update(rule.with(enabled: $0)) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(rule.enabled ? String(localized: "停用这条规则") : String(localized: "启用这条规则"))
    }
}

/// Whether a rule routes anything now, and whether the core has seen the app's processes.
struct AppRuleStatusLabel: View {
    @Environment(ProxyStore.self) private var store
    let rule: AppRule
    let report: AppRuleBuilder.Report?
    let connections: Int

    var body: some View {
        let (kind, text) = status
        StatusBadge(kind: kind, text: text, compact: true)
    }

    private var status: (StatusKind, String) {
        switch report?.status(of: rule.id) {
        case .disabled?: return (.neutral, String(localized: "已停用"))
        case .followsProfile?: return (.neutral, String(localized: "按配置的规则"))
        case .missingTargets(let names)?: return (.failure, String(localized: "出口“\(names.joined(separator: "”“"))”已不存在，这部分流量按配置的规则走"))
        case .shadowed(let id)?:
            let index = (store.activeProfileID.map { store.appRules(of: $0) } ?? []).firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
            return (.warning, String(localized: "第 \(index) 条已包含这个应用，这条不会匹配"))
        case .active?:
            switch store.appRoutingGate {
            case .inEffect:
                if connections > 0 { return (.success, String(localized: "生效中 · 已识别 \(connections) 个连接")) }
                return (.success, rule.app.sharesProcesses ? String(localized: "生效中 · 它的部分流量来自共享的系统进程") : String(localized: "生效中 · 现在没有它的连接"))
            case .coreStopped: return (.neutral, String(localized: "启动后生效"))
            case .notRuleMode, .processMatchingOff: return (.warning, String(localized: "未生效"))
            }
        case nil: return (.neutral, String(localized: "正在检查…"))
        }
    }
}

/// The selected rule: what it covers, its domain routes, and the rules it writes.
struct AppRuleDetail: View {
    @Environment(ProxyStore.self) private var store
    let rule: AppRule
    let report: AppRuleBuilder.Report?
    let targets: (groups: [String], nodes: [String])
    let update: (AppRule) -> Void
    let addDomain: () -> Void
    let removeDomain: (AppRule.DomainRoute.ID) -> Void
    var body: some View { content }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                AppIcon(path: rule.app.root, size: 32)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(rule.app.name).font(.headline)
                    // Paths and identifiers cut in the middle, never wrapped: a narrow page otherwise
                    // hyphenates them into names that do not exist.
                    Text(rule.app.root).font(Typography.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(rule.app.root)
                    if let id = rule.app.bundleID {
                        Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(id)
                    }
                }
                Spacer(minLength: 0)
                Button("重新连接") { Task { await store.reconnect(rule.app) } }
                    .secondaryAction()
                    .disabled(!store.isRunning)
                    .help("关闭这个应用现有的连接，让它按新规则重新连接；其他应用的连接不受影响")
            }
            notes
            domains
            DisclosureGroup("写入配置的规则") {
                let lines = report?.lines(of: rule.id).map(\.text) ?? []
                Text(lines.isEmpty ? String(localized: "（没有）") : lines.joined(separator: "\n"))
                    .font(Typography.codeSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            switch rule.app.flavor {
            case .webKit:
                StatusBadge(kind: .warning, text: String(localized: "网页内容的请求由系统的 WebKit 网络进程发出，所有 WebKit 应用共用它，无法单独归到这个应用。"), compact: true)
            case .system:
                StatusBadge(kind: .warning, text: String(localized: "系统应用的部分流量由共享的系统进程发出，不会匹配这条规则。"), compact: true)
            case .electron, .chromium:
                StatusBadge(kind: .info, text: String(localized: "包括应用包里的 \(rule.app.helpers.count) 个辅助进程（网络、渲染等）。"), compact: true)
                    .help(rule.app.helpers.map(\.name).joined(separator: "\n"))
            case .native where !rule.app.helpers.isEmpty:
                StatusBadge(kind: .info, text: String(localized: "包括应用包里的 \(rule.app.helpers.count) 个辅助进程。"), compact: true)
                    .help(rule.app.helpers.map(\.name).joined(separator: "\n"))
            case .native, .commandLine:
                EmptyView()
            }
            if rule.app.isTranslocated {
                StatusBadge(kind: .warning, text: String(localized: "这个应用从隔离位置运行，路径每次启动都会变。请先把它移到“应用程序”文件夹。"), compact: true)
            } else if !FileManager.default.fileExists(atPath: rule.app.root) {
                StatusBadge(kind: .warning, text: String(localized: "在这个位置找不到它了，规则不会匹配。"), compact: true)
            }
        }
    }

    private var domains: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("域名例外").font(.subheadline.weight(.semibold))
                Text("先于这个应用的出口匹配").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("添加…", action: addDomain).controlSize(.small)
            }
            ForEach(rule.domains) { route in
                HStack(spacing: Spacing.sm) {
                    // The words as one element; the remove button stays its own, so activating
                    // the route's text never removes it.
                    HStack(spacing: Spacing.sm) {
                        Text(AddRuleSheet.title(of: route.matchType)).font(.caption).foregroundStyle(.secondary)
                        Text(route.value).font(Typography.code).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(route.value)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(route.target.title)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button { removeDomain(route.id) } label: { Label("移除", systemImage: "minus.circle") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("移除这个域名例外")
                }
            }
        }
    }
}

/// Adds an app: one found on this Mac (installed or running), or any app or tool picked by hand.
struct AppPickerSheet: View {
    enum Filter: Hashable { case all, running, installed }

    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: Set<String>
    let targets: (groups: [String], nodes: [String])
    let add: (AppIdentity, AppRule.Target) -> Void
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var selection: String?
    @State private var picked: AppIdentity?
    @State private var target = AppRule.Target.direct
    @State private var choosing = false
    @State private var pickError: String?

    private var apps: [AppIdentity] {
        var list: [AppIdentity]
        switch filter {
        case .running: list = store.runningApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .installed: list = store.appCatalog
        case .all: list = store.appCatalog + store.runningApps.filter { app in !store.appCatalog.contains { $0.root == app.root } }
        }
        if let picked, !list.contains(where: { $0.root == picked.root }) { list.insert(picked, at: 0) }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(text) || ($0.bundleID?.lowercased().contains(text) ?? false) }
    }

    private var chosen: AppIdentity? { apps.first { $0.root == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("添加应用").font(.title3.weight(.semibold))
            HStack(spacing: Spacing.sm) {
                TextField("搜索应用", text: $query).textFieldStyle(.roundedBorder)
                SegmentedControl(label: String(localized: "显示"), selection: $filter, options: [
                    .init(value: .all, title: String(localized: "全部")),
                    .init(value: .running, title: String(localized: "正在运行")),
                    .init(value: .installed, title: String(localized: "已安装")),
                ])
                .fixedSize()
            }
            appList
            if let pickError { StatusBadge(kind: .failure, text: pickError) }
            Form {
                AppTargetPicker(title: String(localized: "出口"), target: $target, targets: targets)
            }
            .formStyle(.grouped)
            .frame(height: 64)
            HStack {
                Button("选择其他应用或命令行工具…") { choosing = true }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("添加") {
                    if let chosen { add(chosen, target) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .primaryAction(.regular)
                .disabled(chosen == nil || chosen.map { existing.contains($0.root) } == true)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 560)
        .onAppear { store.loadApps() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application, .unixExecutable, .item]) { result in
            pickError = nil
            guard case .success(let url) = result else { return }
            guard let app = AppDiscovery.identity(ofPicked: url) else {
                pickError = String(localized: "“\(url.lastPathComponent)”不是应用或可执行文件。")
                return
            }
            picked = app
            selection = app.root
        }
    }

    @ViewBuilder private var appList: some View {
        let apps = apps
        if apps.isEmpty {
            StateView(symbol: store.scanningApps ? "hourglass" : "magnifyingglass",
                      title: store.scanningApps ? String(localized: "正在查找应用…") : String(localized: "没有匹配的应用"))
        } else {
            List(apps, id: \.root, selection: $selection) { app in
                HStack(spacing: Spacing.sm) {
                    AppIcon(path: app.root)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).lineLimit(1)
                        Text(app.bundleID ?? app.root).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if existing.contains(app.root) { Tag(text: String(localized: "已有规则")) }
                    if store.runningApps.contains(where: { $0.root == app.root }) { Tag(text: String(localized: "正在运行")) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One domain of an app sent elsewhere than the rest of its traffic.
struct DomainRouteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let app: AppIdentity
    let targets: (groups: [String], nodes: [String])
    let add: (AppRule.DomainRoute) -> Void
    @State private var matchType = "DOMAIN-SUFFIX"
    @State private var value = ""
    @State private var target = AppRule.Target.direct

    private var route: AppRule.DomainRoute { .init(matchType: matchType, value: value, target: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("为“\(app.name)”添加域名例外").font(.title3.weight(.semibold))
                Text("只对这个应用的连接起作用，先于它的出口匹配。").font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Picker("匹配方式", selection: $matchType) {
                    ForEach(AppRule.DomainRoute.matchTypes, id: \.self) { Text(AddRuleSheet.title(of: $0)).tag($0) }
                }
                .neutralControl()
                TextField("域名", text: $value, prompt: Text(verbatim: "example.com"))
                AppTargetPicker(title: String(localized: "出口"), target: $target, targets: targets, allowsFollowProfile: false)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("添加") {
                    add(route)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .primaryAction(.regular)
                .disabled(!route.isValid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
    }
}
