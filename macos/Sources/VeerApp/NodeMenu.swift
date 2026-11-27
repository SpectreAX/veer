import SwiftUI
import VeerCore
import VeerProxy

/// A group's members as its node menu lists them, one line each. Past `flatLimit` members the
/// nodes fold into one submenu per region (with its count and best delay) so the menu fits on
/// screen; sub-groups and DIRECT stay at the top. Shared by the menu bar's SwiftUI menu and the
/// pages' quick-switch menus, which make it only as they open.
struct NodeMenuBuckets: Equatable {
    struct Item: Identifiable, Equatable {
        let name: String
        let title: String
        let selected: Bool
        var id: String { name }
    }

    struct Region: Identifiable, Equatable {
        let code: String?
        /// Without the mark for the node in use, which each menu shows its own way.
        let title: String
        let containsSelected: Bool
        let items: [Item]
        var id: String { code ?? "" }
    }

    static let flatLimit = 12

    /// All the members when there are few, else the sub-groups and built-ins.
    let top: [Item]
    /// Empty when the members are listed flat.
    let regions: [Region]

    /// `region` places a node; `delay` is its latest delay in ms (0 for a failure, nil untested).
    init(group: ProxyStore.Group, region: (String) -> String?, delay: (ProxyStore.Group.Member) -> Int?) {
        func item(_ member: ProxyStore.Group.Member) -> Item {
            Item(name: member.name, title: "\(member.name)    \(Format.delay(delay(member)))", selected: member.name == group.now)
        }
        guard group.members.count > Self.flatLimit else {
            top = group.members.map(item)
            regions = []
            return
        }
        let isTop: (ProxyStore.Group.Member) -> Bool = { $0.isGroup || NodeMapView.builtins.contains($0.name) }
        top = group.members.filter(isTop).map(item)
        let grouped = Dictionary(grouping: group.members.filter { !isTop($0) }) { region($0.name) }
        // The regions with the most nodes first; unknown ones last.
        regions = grouped.sorted { lhs, rhs in
            if (lhs.key == nil) != (rhs.key == nil) { return rhs.key == nil }
            return (lhs.value.count, rhs.key ?? "") > (rhs.value.count, lhs.key ?? "")
        }
        .map { code, members in
            let place = code.flatMap(NodeLocator.place)
            let name = place.map { "\($0.flag) \($0.name)" } ?? String(localized: "其他")
            let best = members.map(delay).reduce(nil, NodeMapView.better)
            return Region(code: code, title: "\(name) · \(members.count) · \(Format.delay(best))",
                          containsSelected: members.contains { $0.name == group.now }, items: members.map(item))
        }
    }

    /// The same lines for `LazyPullDown`.
    var entries: [PullDownEntry] {
        let items = top.map { PullDownEntry(title: $0.title, checked: $0.selected, kind: .item(id: $0.name)) }
        guard !regions.isEmpty else { return items }
        return items + (items.isEmpty ? [] : [.separator]) + regions.map { region in
            PullDownEntry(title: region.title, checked: region.containsSelected,
                          kind: .submenu(region.items.map { PullDownEntry(title: $0.title, checked: $0.selected, kind: .item(id: $0.name)) }))
        }
    }
}

extension ProxyStore {
    /// A group's node menu as it stands now: regions as the store places them, the latest delays.
    func nodeMenu(_ group: Group) -> NodeMenuBuckets {
        NodeMenuBuckets(group: group, region: region(of:)) { [delays] member in delays[member.name]?.legacyDelay ?? member.delay }
    }
}

/// The node menu as SwiftUI menu items, for the menu bar's own menu. Made with the menu, so only
/// where that menu is small or made rarely; the pages use `GroupQuickSwitchMenu`.
struct NodeMenuItems: View {
    @Environment(ProxyStore.self) private var store
    let group: ProxyStore.Group

    var body: some View {
        let menu = store.nodeMenu(group)
        ForEach(menu.top) { item($0) }
        if !menu.regions.isEmpty {
            if !menu.top.isEmpty { Divider() }
            ForEach(menu.regions) { region in
                Menu {
                    ForEach(region.items) { item($0) }
                } label: {
                    // A submenu's title shows no icon, so the mark is part of the text.
                    Text(verbatim: (region.containsSelected ? "✓ " : "") + region.title)
                }
            }
        }
    }

    @ViewBuilder private func item(_ item: NodeMenuBuckets.Item) -> some View {
        Button { store.select(item.name, in: group.name) } label: {
            if item.selected { Label(item.title, systemImage: "checkmark") } else { Text(verbatim: item.title) }
        }
    }
}

/// A select group's node in use, as a pull-down menu of every member with its delay: switching
/// without opening the group. Its items are made as it opens (`LazyPullDown`).
struct GroupQuickSwitchMenu: View {
    @Environment(ProxyStore.self) private var store
    let group: ProxyStore.Group
    let title: String
    var font: NSFont.TextStyle = .callout
    var truncation: NSLineBreakMode = .byTruncatingTail

    var body: some View {
        let store = store, group = group
        LazyPullDown(title: title, font: font, truncation: truncation, help: String(localized: "切换节点"),
                     // Which group's node it is, without the arrow, which VoiceOver would read out.
                     label: String(localized: "“\(group.name)”使用的节点"), value: group.now ?? "—",
                     entries: { store.nodeMenu(store.groups.first { $0.name == group.name } ?? group).entries },
                     choose: { store.select($0, in: group.name) })
    }
}
