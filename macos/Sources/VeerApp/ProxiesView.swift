import SwiftUI
import VeerCore
import VeerProxy

/// The profiles, then policy groups and their members: pick a node for a select group, test delays.
struct ProxiesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var query = ""
    @Environment(\.proxiesStartingQuery) private var startingQuery
    @AppStorage("proxiesShowMap") private var showMap = false
    /// App Routing takes the place of the grid and the map; saved apart so the map choice stays.
    @AppStorage("proxiesShowApps") private var showApps = false

    enum Display: Hashable { case grid, map, apps }

    private var display: Binding<Display> {
        Binding(get: { showApps ? .apps : showMap ? .map : .grid }, set: { value in
            showApps = value == .apps
            if value != .apps { showMap = value == .map }
        })
    }

    /// Groups whose name or members match the search; members filtered to the matches.
    private var shownGroups: [ProxyStore.Group] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            if group.name.lowercased().contains(text) { return group }
            let members = group.members.filter { $0.name.lowercased().contains(text) }
            return members.isEmpty ? nil : ProxyStore.Group(name: group.name, type: group.type, now: group.now, members: members)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Only what needs saying: no profile cards over the nodes (Manage Profiles has them).
            if !store.profiles.isEmpty { ProxiesNotices() }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .onAppear { if let startingQuery { query = startingQuery } }
            .pageToolbar(.proxies) {
                Button { store.openImport() } label: { Label("导入配置", systemImage: "plus") }.help("导入配置（⌘O）")
                GlassSwitch(label: String(localized: "显示方式"), selection: display, options: [
                    .init(value: .grid, title: String(localized: "网格"), symbol: "square.grid.2x2"),
                    .init(value: .map, title: String(localized: "地图"), symbol: "map"),
                    .init(value: .apps, title: String(localized: "应用分流"), symbol: "app.badge.checkmark"),
                ])
                // App Routing works with the core stopped; the grid and the map then show why they are empty.
                .disabled(store.profiles.isEmpty)
                let allCollapsed = !store.groups.isEmpty && store.groups.allSatisfy { store.collapsedGroups.contains($0.name) }
                Button { store.setAllCollapsed(!allCollapsed) } label: {
                    allCollapsed ? Label("全部展开", systemImage: "rectangle.expand.vertical")
                                 : Label("全部收起", systemImage: "rectangle.compress.vertical")
                }
                .help(allCollapsed ? String(localized: "展开全部策略组") : String(localized: "收起全部策略组"))
                .disabled(store.groups.isEmpty || showMap || showApps)
            } content: {
                ToolbarSearchField(text: $query, prompt: searchPrompt)
            }
    }

    private var searchPrompt: Text {
        switch display.wrappedValue {
        case .grid: Text("搜索节点或策略组")
        case .map: Text("搜索节点或地区")
        case .apps: Text("搜索应用规则")
        }
    }

    @ViewBuilder private var content: some View {
        if !store.profiles.isEmpty, showApps {
            AppRoutingView(query: query)
        } else if store.profiles.isEmpty {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "支持订阅链接、Mihomo / Clash 配置文件、Base64 订阅内容和节点分享链接。"),
                      actionTitle: String(localized: "导入配置…")) { store.openImport() }
        } else if !store.isRunning {
            CoreNotRunningView(symbol: "point.3.connected.trianglepath.dotted", message: String(localized: "启动后可以在这里切换节点和测试延迟。"))
        } else if let target = store.switchingTo, store.groups.isEmpty {
            StateView(loading: String(localized: "正在切换到“\(store.profiles.first { $0.id == target }?.name ?? "")”…"))
        } else if store.groups.isEmpty {
            StateView(symbol: "square.stack.3d.up.slash", title: String(localized: "这个配置没有策略组"),
                      message: String(localized: "所有流量按规则直接发往节点或直连。"))
        } else if showMap {
            NodeMapView(query: query, clearSearch: clearSearch)
        } else {
            // The same scroll view whatever the search finds: taking it away for an empty state
            // would take the keyboard focus out of the search field, in the middle of typing.
            ScrollView {
                if shownGroups.isEmpty {
                    StateView(symbol: "magnifyingglass", title: String(localized: "没有匹配“\(query)”的节点或策略组"),
                              actionTitle: String(localized: "清除搜索"), action: clearSearch)
                        .frame(minHeight: 320)
                }
                // Not lazy: as sections collapse, those arriving from below the window would have no
                // earlier place to move from, and slid over the rest. Each one's nodes are still lazy.
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(shownGroups) { GroupSection(group: $0) }
                }
                .padding(Spacing.xl)
            }
        }
    }

    private func clearSearch() {
        ToolbarSearchFocus.clear($query)
    }
}

extension ProxyStore {
    func toggleCollapsed(_ group: String) {
        withCollapseAnimation {
            if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        }
    }

    func setAllCollapsed(_ collapsed: Bool) {
        withCollapseAnimation { collapsedGroups = collapsed ? Set(groups.map(\.name)) : [] }
    }

    /// Around the change, so the sections below move with the one that changes. An animation on each
    /// section would animate its own height while its neighbours jumped. The menu bar's commands come
    /// through here too, where there is no view to read Reduce Motion from.
    private func withCollapseAnimation(_ change: () -> Void) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.standard, change)
    }
}

struct GroupSection: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    let group: ProxyStore.Group
    static let tileWidth: CGFloat = 180

    private var collapsed: Bool { store.collapsedGroups.contains(group.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // The type and node on a line of their own when the row runs short, as squeezed into it the
            // group's name goes first. The node stays in reach: a collapsed group has no other way to show it.
            // The same four views in either form: while the Agent panel moves they go from one to
            // the other with the width, and the sections below follow.
            BlendedHeader(spacing: Spacing.sm, rowSpacing: Spacing.xs) {
                title
                typeTag
                // Always one view, whether or not there is a node to show.
                ZStack { quickSwitch }
                // Its symbol alone where the title would otherwise have no room.
                ViewThatFits(in: .horizontal) {
                    actions(compact: false)
                    actions(compact: true)
                }
            }
            if !collapsed {
            SteadyGrid(minimum: GroupSection.tileWidth, spacing: Spacing.sm, alignment: .leading) {
                ForEach(group.members) { member in
                    NodeTile(member: member, flag: flag(for: member), selected: member.name == group.now, selectable: group.isSelectable) {
                        store.select(member.name, in: group.name)
                    }
                    .contextMenu {
                        Button("问 Agent…") { ask(String(localized: "关于节点“\(member.name)”（在“\(group.name)”里）：")) }
                        if !member.isGroup, !NodeMapView.builtins.contains(member.name), !NodeCleanup.isInfoNode(member.name) {
                            RegionMarkMenu(node: member.name)
                        }
                    }
                }
            }
            .transition(.opacity)
            }
        }
        .panel()
        // Nodes fading out as a section closes would show past its edge.
        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    private var title: some View {
        Button { store.toggleCollapsed(group.name) } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.name).font(.headline).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? String(localized: "展开“\(group.name)”") : String(localized: "收起“\(group.name)”"))
        .accessibilityLabel(collapsed ? String(localized: "展开“\(group.name)”") : String(localized: "收起“\(group.name)”"))
    }

    private var typeTag: some View { Tag(text: Self.typeLabel(group.type)) }

    /// `compact` leaves the Ask Agent menu its symbol, and the row its width.
    private func actions(compact: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Menu {
                Button("换到延迟最低的节点") { ask(String(localized: "“\(group.name)”换到延迟最低的节点")) }
                Button("哪些网站走这个策略组？") { ask(String(localized: "哪些网站走“\(group.name)”？")) }
                Button("问 Agent…") { ask(String(localized: "关于策略组“\(group.name)”：")) }
            } label: {
                if compact {
                    Label("问 Agent", systemImage: "sparkles").labelStyle(.iconOnly)
                } else {
                    Label("问 Agent", systemImage: "sparkles")
                }
            }
            .menuStyle(.borderlessButton).fixedSize().neutralControl()
            .help("让 Agent 处理这个策略组")
            // As the map's region test: the spinner takes the button's place, so the row does not move
            // as a test starts, and the button is unavailable when a test could not start.
            let scope = LatencyScope.group(group.name)
            let testing = store.testingScopes.contains(scope)
            ZStack(alignment: .trailing) {
                Button("测速") { store.testDelay(group.name) }
                    .secondaryAction()
                    .fixedSize()
                    .opacity(testing ? 0 : 1)
                    // Also when nothing in it can be tested (only REJECT, PASS and the like).
                    .disabled(!store.canStartLatencyTest(scope) || store.testableMembers(of: group).isEmpty)
                    .accessibilityLabel(String(localized: "为“\(group.name)”测速"))
                    .accessibilityHidden(testing)
                    .help("测试这个策略组里每个成员的延迟")
                if testing { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "正在测速")) }
            }
        }
    }

    /// The node in use, and for a select group a menu of every member with its delay: switching
    /// without opening the group. It truncates in the width the header gives it.
    @ViewBuilder private var quickSwitch: some View {
        if let now = group.now {
            if group.isSelectable {
                Menu {
                    NodeMenuItems(group: group)
                } label: {
                    Text(verbatim: "→ \(now)").lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).neutralControl()
                .font(.callout)
                .help("切换节点")
                // Which group's node it is, without the arrow, which VoiceOver would read out.
                .accessibilityLabel(String(localized: "“\(group.name)”使用的节点"))
                .accessibilityValue(now)
            } else {
                Text(verbatim: "→ \(now)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(String(localized: "“\(group.name)”使用的节点"))
                    .accessibilityValue(now)
            }
        }
    }

    /// A flag for a node whose name has none, from a hand-set mark or a code or city in the name.
    private func flag(for member: ProxyStore.Group.Member) -> String? {
        guard !member.isGroup, !NodeLocator.hasFlag(member.name) else { return nil }
        return store.region(of: member.name).flatMap(NodeLocator.place)?.flag
    }

    /// Opens the Agent beside this page with `text` in the composer, in a conversation about this profile.
    private func ask(_ text: String) { agent.open(asking: text) }

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "Selector": String(localized: "手动选择")
        case "URLTest": String(localized: "自动选择")
        case "Fallback": String(localized: "故障转移")
        case "LoadBalance": String(localized: "负载均衡")
        case "Relay": String(localized: "链式")
        default: type
        }
    }
}

/// One member: its name, delay in words and color, and a check when it is the one in use. In a
/// select group it is a button; in an automatic group it is plain content, since clicks do nothing.
private struct NodeTile: View {
    let member: ProxyStore.Group.Member
    let flag: String?
    let selected: Bool
    let selectable: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        if selectable {
            Button(action: select) { tile }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(member.name)
                .accessibilityLabel(String(localized: "\(member.name)，延迟 \(Format.delay(member.state))"))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            tile
                .help(String(localized: "\(member.name)（这个策略组按延迟自动选择）"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selected ? String(localized: "\(member.name)，延迟 \(Format.delay(member.state))，正在使用")
                                    : String(localized: "\(member.name)，延迟 \(Format.delay(member.state))"))
        }
    }

    /// The core's own words when a test failed, for the tooltip.
    private var failureReason: String? {
        if case .failed(let reason) = member.state, !reason.isEmpty { return reason }
        return nil
    }

    private var tile: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: selected ? "checkmark.circle.fill" : member.isGroup ? "square.stack.3d.up" : "circle")
                .foregroundStyle(selected ? Color.veerAccent : Color.secondary)
                .opacity(selectable || selected || member.isGroup ? 1 : 0)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: flag.map { "\($0) \(member.name)" } ?? member.name).lineLimit(1).truncationMode(.middle)
                Text(Format.delay(member.state)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(member.state).color)
                    .help(failureReason ?? "")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 44)
        .background(selected ? Color.veerAccent.opacity(0.12) : hovering ? Color.subtleFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(selected ? Color.veerAccent.opacity(0.5) : Color.separatorLine))
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
}

/// Sets where a node exits when its name does not say, or goes back to reading the name.
private struct RegionMarkMenu: View {
    let node: String

    var body: some View {
        Menu("标记地区") { RegionMarkItems(node: node) }
    }
}

struct RegionMarkItems: View {
    @Environment(ProxyStore.self) private var store
    let node: String

    var body: some View {
        let marked = store.regionMarks[node]
        Button { store.markRegion(node, code: nil) } label: {
            if marked == nil { Label("按名称识别", systemImage: "checkmark") } else { Text("按名称识别") }
        }
        Divider()
        ForEach(NodeLocator.places.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { place in
            Button { store.markRegion(node, code: place.code) } label: {
                if marked == place.code {
                    Label("\(place.flag) \(place.name)", systemImage: "checkmark")
                } else {
                    Text(verbatim: "\(place.flag) \(place.name)")
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// Snapshots only: the search the page opens with, as if typed.
    @Entry var proxiesStartingQuery: String?
}
