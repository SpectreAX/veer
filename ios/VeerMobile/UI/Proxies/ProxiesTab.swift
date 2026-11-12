import SwiftUI

/// Policy groups stay live while navigating: destinations look them up by name, not a snapshot.
struct ProxiesTab: View {
    @Environment(ProxyStore.self) private var store
    @State private var query = ""

    private var shownGroups: [ProxyStore.Group] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return store.groups }
        return store.groups.filter { group in
            group.name.localizedStandardContains(text)
                || group.members.contains { $0.name.localizedStandardContains(text) }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("page.proxies")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $query, prompt: Text("搜索节点或策略组"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.testAll() } label: {
                            HStack(spacing: Spacing.s) {
                                if store.isTestingAll { ProgressView().controlSize(.small) }
                                Text("测速全部")
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(!store.isRunning || store.groups.isEmpty || !store.testingGroups.isEmpty)
                        .accessibilityIdentifier("proxies-test-all")
                    }
                }
                .navigationDestination(for: String.self) { name in
                    GroupDetail(groupName: name)
                }
        }
    }

    @ViewBuilder private var content: some View {
        if store.activeProfile == nil || !store.isRunning {
            ProxiesAvailabilityView()
        } else if store.groups.isEmpty {
            ContentUnavailableView("这个配置没有策略组", systemImage: "square.stack.3d.up.slash",
                                   description: Text("所有流量按规则直接发往节点或直连。"))
                .accessibilityIdentifier("proxies-no-groups")
        } else {
            List {
                Section {
                    ForEach(shownGroups) { group in
                        NavigationLink(value: group.name) {
                            ProxyGroupRow(group: group)
                        }
                        .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.s, trailing: Spacing.l))
                        .accessibilityIdentifier("proxies-group-\(store.groups.firstIndex(where: { $0.id == group.id }) ?? 0)")
                    }
                } footer: {
                    if !shownGroups.isEmpty { Text("轻点策略组查看节点并切换。") }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("proxies-list")
            .overlay {
                if shownGroups.isEmpty {
                    ContentUnavailableView {
                        Label { Text("没有匹配“\(query)”的节点或策略组") } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("proxies-search-empty")
                }
            }
        }
    }
}

private struct ProxyGroupRow: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let group: ProxyStore.Group

    private var selected: ProxyStore.Group.Member? {
        let name = store.selectedMember(of: group)
        return group.members.first { $0.name == name }
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if typeSize.isAccessibilitySize {
                    Text(group.name).font(.body)
                    Tag(text: ProxyPresentation.typeLabel(group.type))
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.xs) {
                            Text(group.name).font(.body)
                            Tag(text: ProxyPresentation.typeLabel(group.type))
                        }
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(group.name).font(.body)
                            Tag(text: ProxyPresentation.typeLabel(group.type))
                        }
                    }
                }
                Text(selectedName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                if typeSize.isAccessibilitySize { delay }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { delay }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var selectedName: String {
        guard let name = store.selectedMember(of: group) else { return "—" }
        return ProxyPresentation.nodeName(name, isNode: selected?.isNode == true, store: store)
    }

    @ViewBuilder private var delay: some View {
        if store.isTesting(group.name) {
            ProgressView().controlSize(.small).accessibilityLabel("测速")
        } else {
            DelayText(delay: selected?.delay)
        }
    }

    private var accessibilityDescription: String {
        [group.name, ProxyPresentation.typeLabel(group.type), String(localized: "当前出口"), selectedName,
         store.isTesting(group.name) ? String(localized: "测速") : ProxyPresentation.spokenDelay(selected?.delay)]
            .joined(separator: "，")
    }
}
