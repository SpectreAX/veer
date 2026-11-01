import SwiftUI
import VeerCore
import VeerProxy

/// The profiles, then policy groups and their members: pick a node for a select group, test delays.
struct ProxiesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var query = ""
    @AppStorage("proxiesShowMap") private var showMap = false

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
            if !store.profiles.isEmpty { ProfileBar() }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .pageToolbar(.proxies) {
                GlassSwitch(label: String(localized: "显示方式"), selection: $showMap, options: [
                    .init(value: false, title: String(localized: "网格"), symbol: "square.grid.2x2"),
                    .init(value: true, title: String(localized: "地图"), symbol: "map"),
                ])
                // Neither shows anything until there are groups to show.
                .disabled(!store.isRunning || store.groups.isEmpty)
                let allCollapsed = !store.groups.isEmpty && store.groups.allSatisfy { store.collapsedGroups.contains($0.name) }
                Button { store.setAllCollapsed(!allCollapsed) } label: {
                    allCollapsed ? Label("全部展开", systemImage: "rectangle.expand.vertical")
                                 : Label("全部收起", systemImage: "rectangle.compress.vertical")
                }
                .help(allCollapsed ? String(localized: "展开全部策略组") : String(localized: "收起全部策略组"))
                .disabled(store.groups.isEmpty || showMap)
            } content: {
                ToolbarSearchField(text: $query, prompt: Text("搜索节点或策略组"))
            }
    }

    @ViewBuilder private var content: some View {
        if store.profiles.isEmpty {
            StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                      message: String(localized: "支持订阅链接、Mihomo / Clash 配置文件、Base64 订阅内容和节点分享链接。"),
                      actionTitle: String(localized: "导入配置…")) { store.openImport() }
        } else if !store.isRunning {
            CoreNotRunningView(symbol: "point.3.connected.trianglepath.dotted", message: String(localized: "启动后可以在这里切换节点和测试延迟。"))
        } else if store.groups.isEmpty {
            StateView(symbol: "square.stack.3d.up.slash", title: String(localized: "这个配置没有策略组"),
                      message: String(localized: "所有流量按规则直接发往节点或直连。"))
        } else if showMap {
            NodeMapView(query: query)
        } else {
            // The same scroll view whatever the search finds: taking it away for an empty state
            // would take the keyboard focus out of the search field, in the middle of typing.
            ScrollView {
                if shownGroups.isEmpty {
                    StateView(symbol: "magnifyingglass", title: String(localized: "没有匹配“\(query)”的节点或策略组"))
                        .frame(minHeight: 320)
                }
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(shownGroups) { GroupSection(group: $0) }
                }
                .padding(Spacing.xl)
            }
        }
    }
}

private struct GroupSection: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    let group: ProxyStore.Group
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: Spacing.sm)]

    private var collapsed: Bool { store.collapsedGroups.contains(group.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Button { store.toggleCollapsed(group.name) } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(group.name).font(.headline).lineLimit(1).truncationMode(.middle)
                        Tag(text: Self.typeLabel(group.type))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? String(localized: "展开") : String(localized: "proxies.collapse", defaultValue: "收起"))
                .accessibilityLabel(collapsed ? String(localized: "展开“\(group.name)”") : String(localized: "收起“\(group.name)”"))
                quickSwitch
                Spacer()
                if store.testingGroups.contains(group.name) {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button("换到延迟最低的节点") { ask(String(localized: "“\(group.name)”换到延迟最低的节点")) }
                    Button("哪些网站走这个策略组？") { ask(String(localized: "哪些网站走“\(group.name)”？")) }
                    Button("问 AI…") { ask(String(localized: "关于策略组“\(group.name)”：")) }
                } label: { Label("问 AI", systemImage: "sparkles") }
                .menuStyle(.borderlessButton).fixedSize().neutralControl()
                .help("让 Agent 处理这个策略组")
                Button("测速") { store.testDelay(group.name) }
                    .secondaryAction()
                    .disabled(store.testingGroups.contains(group.name))
                    .help("测试这个策略组里每个成员的延迟")
            }
            if !collapsed {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                ForEach(group.members) { member in
                    NodeTile(member: member, flag: flag(for: member), selected: member.name == group.now, selectable: group.isSelectable) {
                        store.select(member.name, in: group.name)
                    }
                    .contextMenu {
                        Button("问 AI…") { ask(String(localized: "关于节点“\(member.name)”（在“\(group.name)”里）：")) }
                        if !member.isGroup, !NodeMapView.builtins.contains(member.name), !NodeCleanup.isInfoNode(member.name) {
                            RegionMarkMenu(node: member.name)
                        }
                    }
                }
            }
            }
        }
        .panel()
        .animation(Motion.standard, value: collapsed)
    }

    /// The node in use, and for a select group a menu of every member with its delay: switching
    /// without opening the group.
    @ViewBuilder private var quickSwitch: some View {
        if let now = group.now {
            if group.isSelectable {
                Menu {
                    NodeMenuItems(group: group)
                } label: {
                    Text(verbatim: "→ \(now)").lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).fixedSize().neutralControl()
                .font(.callout)
                .help("切换节点")
            } else {
                Text(verbatim: "→ \(now)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                .accessibilityLabel(String(localized: "\(member.name)，延迟 \(Format.delay(member.delay))"))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            tile
                .help(String(localized: "\(member.name)（这个策略组按延迟自动选择）"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selected ? String(localized: "\(member.name)，延迟 \(Format.delay(member.delay))，正在使用")
                                    : String(localized: "\(member.name)，延迟 \(Format.delay(member.delay))"))
        }
    }

    private var tile: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: selected ? "checkmark.circle.fill" : member.isGroup ? "square.stack.3d.up" : "circle")
                .foregroundStyle(selected ? Color.veerAccent : Color.secondary)
                .opacity(selectable || selected || member.isGroup ? 1 : 0)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: flag.map { "\($0) \(member.name)" } ?? member.name).lineLimit(1).truncationMode(.middle)
                Text(Format.delay(member.delay)).font(.caption.monospacedDigit()).foregroundStyle(Format.delayKind(member.delay).color)
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
