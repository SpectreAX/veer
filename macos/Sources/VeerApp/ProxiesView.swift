import SwiftUI
import VeerProxy

/// Policy groups and their members: pick a node for a select group, test delays.
struct ProxiesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var query = ""

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
        content
            .searchable(text: $query, placement: .toolbar, prompt: "搜索节点或策略组")
    }

    @ViewBuilder private var content: some View {
        if !store.isRunning {
            StateView(symbol: "point.3.connected.trianglepath.dotted", title: store.phase == .starting ? "内核正在启动…" : "内核没有运行",
                      message: store.activeProfile == nil ? "先导入一个配置。" : "启动后可以在这里切换节点和测试延迟。",
                      actionTitle: store.activeProfile == nil || store.phase == .starting ? nil : "启动") { store.start() }
        } else if store.groups.isEmpty {
            StateView(symbol: "square.stack.3d.up.slash", title: "这个配置没有策略组", message: "所有流量按规则直接发往节点或直连。")
        } else if shownGroups.isEmpty {
            StateView(symbol: "magnifyingglass", title: "没有匹配“\(query)”的节点或策略组")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if let notice = store.notice { StatusBadge(kind: .warning, text: notice) }
                    ForEach(shownGroups) { GroupSection(group: $0) }
                }
                .padding(Spacing.xl)
            }
        }
    }
}

private struct GroupSection: View {
    @Environment(ProxyStore.self) private var store
    let group: ProxyStore.Group
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Text(group.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Tag(text: Self.typeLabel(group.type))
                if let now = group.now {
                    Text("→ \(now)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if store.testingGroups.contains(group.name) {
                    ProgressView().controlSize(.small)
                }
                Button("测速") { store.testDelay(group.name) }
                    .buttonStyle(.bordered).neutralControl()
                    .disabled(store.testingGroups.contains(group.name))
                    .help("测试这个策略组里每个成员的延迟")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                ForEach(group.members) { member in
                    MemberTile(member: member, selected: member.name == group.now, selectable: group.isSelectable) {
                        store.select(member.name, in: group.name)
                    }
                }
            }
        }
        .panel()
    }

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "Selector": "手动选择"
        case "URLTest": "自动选择"
        case "Fallback": "故障转移"
        case "LoadBalance": "负载均衡"
        case "Relay": "链式"
        default: type
        }
    }
}

/// One member: its name, delay in words and color, and a check when it is the one in use. In a
/// select group it is a button; in an automatic group it is plain content, since clicks do nothing.
private struct MemberTile: View {
    let member: ProxyStore.Group.Member
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
                .accessibilityLabel("\(member.name)，延迟 \(Format.delay(member.delay))")
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            tile
                .help("\(member.name)（这个策略组按延迟自动选择）")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(member.name)，延迟 \(Format.delay(member.delay))\(selected ? "，正在使用" : "")")
        }
    }

    private var tile: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: selected ? "checkmark.circle.fill" : member.isGroup ? "square.stack.3d.up" : "circle")
                .foregroundStyle(selected ? Color.veerAccent : Color.secondary)
                .opacity(selectable || selected || member.isGroup ? 1 : 0)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(member.name).lineLimit(1).truncationMode(.middle)
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
