import SwiftUI

/// Resolves the latest group on every render, including optimistic selections and refreshed delays.
struct GroupDetail: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let groupName: String
    @State private var selectionFeedback = 0

    private var group: ProxyStore.Group? { store.groups.first { $0.name == groupName } }

    var body: some View {
        content
            .navigationTitle(groupName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.testDelay(groupName) } label: {
                        HStack(spacing: Spacing.s) {
                            if store.isTesting(groupName) { ProgressView().controlSize(.small) }
                            Text("测速")
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(!store.isRunning || group == nil || store.isTesting(groupName))
                    .accessibilityHint("测试这个策略组里每个成员的延迟")
                    .accessibilityIdentifier("group-detail-test")
                }
            }
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .onChange(of: store.selectionErrors[groupName]) { _, error in
                if let error { AccessibilityNotification.Announcement(error).post() }
            }
    }

    @ViewBuilder private var content: some View {
        if store.activeProfile == nil || !store.isRunning {
            ProxiesAvailabilityView()
        } else if let group {
            memberList(group)
        } else {
            ContentUnavailableView("这个配置没有策略组", systemImage: "square.stack.3d.up.slash",
                                   description: Text("所有流量按规则直接发往节点或直连。"))
        }
    }

    private func memberList(_ group: ProxyStore.Group) -> some View {
        let policies = group.members.filter { !$0.isNode }
        let nodes = group.members.filter(\.isNode)
        // The spec's cutoff counts all members; the store's threshold counts just nodes.
        let regions = store.regionSections(of: group, threshold: max(0, 12 - policies.count))
        return List {
            Section {
                ForEach(policies) { member in memberRow(member, in: group) }
            } header: {
                // insetGrouped headers sit ~36 pt in; pull this line back to the large title's
                // text edge (16 + 4 pt) per design review 1, item 6.
                metadata(group)
                    .padding(.leading, -16)
                    .padding(.bottom, Spacing.s)
            } footer: {
                if nodes.isEmpty { groupFooter(group) }
            }
            .textCase(nil)

            if let regions {
                ForEach(regions) { region in
                    Section {
                        ForEach(region.members) { member in memberRow(member, in: group) }
                    } header: {
                        regionHeader(region)
                    } footer: {
                        if region.id == regions.last?.id { groupFooter(group) }
                    }
                    .textCase(nil)
                }
            } else if !nodes.isEmpty {
                Section {
                    ForEach(nodes) { member in memberRow(member, in: group) }
                } footer: {
                    groupFooter(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.xl)
        .accessibilityIdentifier("group-detail-list")
        .animation(reduceMotion ? nil : Motion.quick, value: store.selectedMember(of: group))
    }

    @ViewBuilder private func metadata(_ group: ProxyStore.Group) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Tag(text: ProxyPresentation.typeLabel(group.type))
                memberCount(group)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.xs) {
                    Tag(text: ProxyPresentation.typeLabel(group.type))
                    memberCount(group)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Tag(text: ProxyPresentation.typeLabel(group.type))
                    memberCount(group)
                }
            }
        }
    }

    private func memberCount(_ group: ProxyStore.Group) -> some View {
        HStack(spacing: Spacing.xs) {
            Text("\(group.members.count) 个成员")
            if group.isSelectable { Text(verbatim: "·"); Text("轻点切换") }
        }
        .font(.footnote)
        // Absolute colour: hierarchical .secondary inside a list header resolves one level lighter.
        .foregroundStyle(Color.secondary)
        .accessibilityIdentifier("group-detail-members")
    }

    private func regionHeader(_ region: ProxyStore.RegionSection) -> some View {
        let title = region.place.map { "\($0.flag) \($0.name)" } ?? String(localized: "其他")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                Text(verbatim: "· \(region.members.count) ·")
                DelayText(delay: region.fastest)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                HStack(spacing: Spacing.xs) {
                    Text("\(region.members.count) 个成员")
                    DelayText(delay: region.fastest)
                }
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-region-\(region.code ?? "other")")
    }

    private func memberRow(_ member: ProxyStore.Group.Member, in group: ProxyStore.Group) -> some View {
        ProxyMemberRow(member: member, selected: store.selectedMember(of: group) == member.name,
                       selectable: group.isSelectable,
                       testing: store.isTesting(groupName) || store.isTesting(member.name)) {
            selectionFeedback += 1
            store.select(member.name, in: groupName)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l))
        .contextMenu {
            // The controller currently exposes only group-wide tests. This refreshes the node's
            // actual delay along with its siblings, rather than fabricating a per-node result.
            Button("测速") { store.testDelay(member.isGroup ? member.name : groupName) }
                .disabled(store.isTesting(groupName) || store.isTesting(member.name))
                .accessibilityHint("测试这个策略组里每个成员的延迟")
                .accessibilityIdentifier("node-test-\(member.name)")
        }
    }

    private func groupFooter(_ group: ProxyStore.Group) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if group.isAutomatic { Text("这个策略组会自动选择节点。") }
            if let error = store.selectionErrors[groupName] {
                StatusBadge(kind: .failure, text: error, font: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("group-selection-error")
            }
            if let notice = store.notice {
                StatusBadge(kind: .failure, text: notice, font: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("group-test-error")
            }
        }
        .font(.footnote)
    }
}
