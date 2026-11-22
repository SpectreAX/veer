import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeerCore
import VeerProxy

/// The top of the Proxies page, only while there is something to say: the last action's failure and
/// what "my routing" could not do. The profile cards that used to sit here covered the nodes; the
/// profiles are in Manage Profiles, from the profile menu under the title.
struct ProxiesNotices: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        let notice = store.phase.isFailed ? nil : store.notice
        if notice != nil || store.effective.map(EffectiveWarnings.hasAny) == true {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Held to a few lines, with the rest in a tooltip: wrapped text at its full height
                // would push the page out of place.
                if let notice { StatusBadge(kind: .warning, text: notice).lineLimit(3).help(notice) }
                if let effective = store.effective { EffectiveWarnings(effective: effective) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.sm)
        }
    }
}

/// Every profile, from the profile menu, the Proxy menu or a failed start: switch, update, nodes
/// and routing, export, delete and import, and copies of one subscription to merge.
struct ProfilesSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: Profile?
    @State private var details: Profile?
    @State private var merging: MergePlan?
    @State var removedCopies: [RemovedProfile] = []
    @State var mergeProblem: String?
    @State var restoreResult: String?
    var onImport: () -> Void = {}

    var body: some View {
        VStack(spacing: Spacing.sm) {
            if let details {
                ProfileDetailSheet(profile: details, back: { self.details = nil })
            } else {
                profileList
            }
            if let activity = store.activity {
                ActivityToast(activity: activity, retry: { store.retryActivity() }, close: { store.dismissActivity() })
                    .padding([.horizontal, .bottom], Spacing.md)
            }
        }
        .frame(height: details == nil ? nil : 520)
        .frame(maxHeight: 520)
        .onExitCommand {
            if details != nil { details = nil } else { dismiss() }
        }
        .onChange(of: store.profiles.isEmpty) { _, empty in if empty, removedCopies.isEmpty { dismiss() } }
        .onChange(of: mergeProblem ?? restoreResult) { _, message in
            if let message { Self.announce(message) }
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("管理配置").font(.title3.weight(.semibold))
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: Spacing.sm) {
                        ForEach(store.profiles) { profile in
                            ProfileTile(profile: profile, active: profile.id == store.activeProfileID, width: nil,
                                        showDetails: { details = profile }, delete: { pendingDeletion = profile })
                                .id(profile.id)
                        }
                        duplicates
                    }
                }
                .onAppear { if let active = store.activeProfileID { reader.scrollTo(active) } }
            }
            .frame(minHeight: 120, maxHeight: 380)
            mergeFeedback
            HStack {
                Button("导入配置…", action: onImport)
                Spacer()
                closeButton
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
        .alert("删除配置？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) { if let profile = pendingDeletion { store.delete(profile.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDeletion?.id == store.activeProfileID
                 ? String(localized: "这是正在使用的配置，删除后内核会停止。")
                 : String(localized: "配置文件、订阅链接和“我的分流”会从本机删除。"))
        }
        .confirmationDialog(mergeTitle, isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible) {
            Button("合并") {
                if let plan = merging {
                    do {
                        let removed = try store.mergeDuplicates(plan)
                        removedCopies.append(contentsOf: removed)
                        mergeProblem = nil
                        restoreResult = nil
                        // Said as well as shown, as a restore's result is: the way back is in this sheet.
                        Self.announce(String(localized: "可恢复 \(removedCopies.count) 份已合并的副本"))
                    } catch let error as EditorError {
                        mergeProblem = error.message
                    } catch {
                        mergeProblem = String(localized: "无法合并副本。配置未改动。")
                    }
                }
                merging = nil
            }
            Button("取消", role: .cancel) { merging = nil }
        } message: {
            Text(mergeMessage)
        }
    }

    /// Copies of one subscription link (imported twice before Veer recognized it), with a merge.
    @ViewBuilder private var duplicates: some View {
        ForEach(store.duplicateProfiles(), id: \.first?.id) { copies in
            let plan = store.mergePlan(copies)
            let summary = String(localized: "“\(copies[0].name)”等 \(copies.count) 份配置使用同一个订阅链接")
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    StatusBadge(kind: .warning, text: summary)
                        .lineLimit(2)
                        .help(summary)
                    Spacer(minLength: Spacing.sm)
                    Button("合并…") { merging = plan }
                        .disabled(plan?.remove.isEmpty != false)
                        .accessibilityLabel(Text(String(localized: "合并“\(copies[0].name)”的副本")))
                        .help(String(localized: "保留一份，删除没有自己修改的副本"))
                }
                if plan?.remove.isEmpty != false {
                    Text(String(localized: "这些副本有自己的“我的分流”修改，或无法读取这些修改。"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var mergeFeedback: some View {
        if !removedCopies.isEmpty {
            HStack(spacing: Spacing.sm) {
                Text(String(localized: "可恢复 \(removedCopies.count) 份已合并的副本"))
                Spacer(minLength: Spacing.sm)
                Button("恢复副本") {
                    let remaining = store.restoreMergedCopies(removedCopies)
                    let restored = removedCopies.count - remaining.count
                    removedCopies = remaining
                    mergeProblem = removedCopies.isEmpty ? nil : String(localized: "有 \(removedCopies.count) 份副本未能恢复。你可以重试。")
                    restoreResult = restored > 0 ? String(localized: "已恢复 \(restored) 份副本。") : nil
                }
            }
            .font(.callout)
        }
        if let restoreResult {
            StatusBadge(kind: .success, text: restoreResult)
        }
        if let mergeProblem {
            Label(mergeProblem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// While merged copies can be restored, Return does nothing here: the merge was confirmed with Return,
    /// and a second press closed the sheet and the way back with it. Close still works when clicked.
    @ViewBuilder private var closeButton: some View {
        if Self.closeIsDefault(pendingCopies: removedCopies.count) {
            Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction(.regular)
        } else {
            Button("关闭") { dismiss() }
        }
    }

    static func closeIsDefault(pendingCopies: Int) -> Bool { pendingCopies == 0 }

    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private var mergeTitle: String { String(localized: "合并重复的配置？") }

    private var mergeMessage: String { merging.map(Self.mergeMessage) ?? "" }

    /// The confirmation's text: what stays, and by name what goes.
    static func mergeMessage(_ plan: MergePlan) -> String {
        // Names what goes: the summary row names only the first copy, and a copy may have been renamed.
        let names = plan.remove.map { "“\($0.name)”" }.formatted(.list(type: .and))
        var text = String(localized: "保留“\(plan.keep.name)”，删除 \(plan.remove.count) 份没有自己修改的副本：\(names)。")
        if !plan.keptWithChanges.isEmpty {
            text += String(localized: "另有 \(plan.keptWithChanges.count) 份含有分流修改或无法检查，将保留。")
        }
        return text + String(localized: "相关对话会转到保留的配置。关闭此窗口前可以恢复删除的副本。")
    }
}

/// What the layer could not do for the profile in use.
private struct EffectiveWarnings: View {
    let effective: EffectiveConfig

    static func hasAny(_ effective: EffectiveConfig) -> Bool {
        effective.conflictCount > 0 || !effective.emptiedGroups.isEmpty || !effective.keptNodes.isEmpty
    }

    var body: some View {
        if effective.conflictCount > 0 {
            let text = String(localized: "“我的分流”里有 \(effective.conflictCount) 项修改未能用到更新后的订阅上，打开“节点与分流”查看原因。")
            StatusBadge(kind: .warning, text: text)
                .lineLimit(3)
                .help(text)
        }
        if !effective.emptiedGroups.isEmpty {
            let groups = effective.emptiedGroups.formatted(.list(type: .and))
            let text = String(localized: "取消勾选节点后，这些策略组没有节点了，暂时改为直连：\(groups)")
            StatusBadge(kind: .warning, text: text)
                .lineLimit(3)
                .help(text)
        }
        if !effective.keptNodes.isEmpty {
            let nodes = effective.keptNodes.formatted(.list(type: .and))
            let text = String(localized: "有规则直接使用这些节点，所以它们没有被去掉：\(nodes)")
            StatusBadge(kind: .info, text: text)
                .lineLimit(3)
                .help(text)
        }
    }
}

/// One profile: the card chooses it, as a node's does, and updating and the rest sit beside that.
private struct ProfileTile: View {
    @Environment(ProxyStore.self) private var store
    let profile: Profile
    let active: Bool
    /// The least it takes in a row, where the tiles share the page's width; the whole width when
    /// stacked. Never a fixed width: the card's edge follows the page's at every frame while the
    /// Agent panel moves.
    let width: CGFloat?
    let showDetails: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let nameBesideTag: CGFloat = 96

    private var updating: Bool { store.updatingProfiles.contains(profile.id) }

    private var name: some View {
        Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle).help(profile.name)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button { if !active { store.activate(profile.id) } } label: { summary }
                .buttonStyle(.plain)
                .help(profile.updateError ?? (active ? String(localized: "正在使用这个配置") : String(localized: "使用这个配置")))
                .accessibilityLabel(String(localized: "\(profile.name)，\(profile.updateError ?? usageLine ?? nodeLine)"))
                .accessibilityAddTraits(active ? .isSelected : [])
            if profile.isSubscription {
                Group {
                    if updating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { store.update(profile.id) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "下次自动更新：\(profile.nextUpdate.formatted(date: .abbreviated, time: .shortened))"))
                            .accessibilityLabel(String(localized: "更新订阅"))
                    }
                }
                .frame(width: Spacing.xl)
            }
            Menu { actions } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
                .help("更多操作")
                .accessibilityLabel(String(localized: "更多操作"))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(minWidth: width, idealWidth: width, maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(active ? Color.veerAccent.opacity(0.12) : hovering ? Color.subtleFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(active ? Color.veerAccent.opacity(0.5) : Color.separatorLine))
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    private var summary: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.veerAccent : Color.secondary)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // The tag gives way to the name when there is no room for both.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        name.frame(minWidth: Self.nameBesideTag, alignment: .leading)
                        Tag(text: profile.isSubscription ? String(localized: "订阅") : String(localized: "本地")).fixedSize()
                    }
                    name
                }
                if let error = profile.updateError {
                    StatusBadge(kind: .warning, text: String(localized: "自动更新失败：\(error)"), compact: true).lineLimit(2)
                } else {
                    Text(nodeLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let usageLine { Text(usageLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var actions: some View {
        Button("节点与分流…", action: showDetails)
        Button("导出配置…") { ConfigExport.run(profile, store: store) }
        Divider()
        Button("删除…", role: .destructive, action: delete)
    }

    private var nodeLine: String {
        [String(localized: "\(profile.nodeCount) 个节点"), String(localized: "更新于 \(Format.relative(profile.updatedAt))")].joined(separator: " · ")
    }

    private var usageLine: String? {
        var parts: [String] = []
        if let usage = profile.usage, let total = usage.total, total > 0 {
            parts.append(String(localized: "已用 \(Format.bytes(usage.used ?? 0)) / \(Format.bytes(total))"))
        }
        if let expire = profile.usage?.expire {
            parts.append(String(localized: "\(expire.formatted(date: .numeric, time: .omitted)) 到期"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A profile's nodes, each with a checkbox, and its "my routing" changes.
struct ProfileDetailSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State var tab = Tab.nodes
    @State private var query = ""
    @State private var nodes: [String] = []
    @State private var layer = RoutingLayer()
    @State private var routingReplayError: String?
    var back: (() -> Void)?

    enum Tab: Hashable { case nodes, routing, check }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text(profile.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                SegmentedControl(label: String(localized: "显示"), selection: $tab, options: [
                    .init(value: .nodes, title: String(localized: "节点")),
                    .init(value: .routing, title: String(localized: "我的分流")),
                    .init(value: .check, title: String(localized: "体检")),
                ])
                .fixedSize()
            }
            switch tab {
            case .nodes: nodeList
            case .routing: routingList
            case .check: ConfigCheckList(profile: profile, done: reload)
            }
            HStack {
                if let back { Button("后退", action: back) }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction(.regular)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: back == nil ? 520 : nil)
        .onAppear(perform: reload)
    }

    private var shownNodes: [String] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? nodes : nodes.filter { $0.lowercased().contains(text) }
    }

    @ViewBuilder private var nodeList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                TextField("搜索节点", text: $query).textFieldStyle(.roundedBorder)
                Text("已取消勾选 \(layer.excludedNodes.count) 个").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Text("取消勾选的节点不会出现在任何策略组里。订阅更新后，按节点名称保留勾选状态。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if nodes.isEmpty {
                StateView(symbol: "circle.dashed", title: String(localized: "这个配置里没有节点"))
            } else {
                List(shownNodes, id: \.self) { name in
                    HStack(spacing: Spacing.sm) {
                        Toggle(isOn: Binding(get: { !layer.excludedNodes.contains(name) }, set: { included in
                            store.setNode(name, included: included, in: profile.id)
                            reload()
                        })) {
                            Text(name).lineLimit(1).truncationMode(.middle)
                        }
                        .accentCheckbox()
                        Spacer(minLength: 0)
                        // Marks belong to the profile in use, the one whose nodes it can locate.
                        if profile.id == store.activeProfileID, !NodeMapView.builtins.contains(name), !NodeCleanup.isInfoNode(name) {
                            Menu { RegionMarkItems(node: name) } label: {
                                Image(systemName: store.regionMarks[name] == nil ? "mappin" : "mappin.circle.fill")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
                            .help("标记地区")
                            .accessibilityLabel(String(localized: "标记“\(name)”的地区"))
                            .accessibilityValue(store.regionMarks[name].flatMap(NodeLocator.place)?.name ?? "")
                        }
                    }
                }
                .listStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var routingList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("规则来源", selection: Binding(get: { layer.template ?? "" }, set: { value in
                store.setTemplate(value.isEmpty ? nil : value, for: profile.id)
                reload()
            })) {
                Text("订阅自带的规则").tag("")
                Text(RuleTemplate.title(RuleTemplate.standard)).tag(RuleTemplate.standard)
            }
            .fixedSize()
            .neutralControl()
            Text(Self.routingNote(template: layer.template))
                .font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let routingReplayError {
                StatusBadge(kind: .failure, text: routingReplayError).fixedSize(horizontal: false, vertical: true)
            }
            edits
        }
        .task(id: layerNeedingReplay) {
            routingReplayError = nil
            guard layerNeedingReplay != nil else { return }
            do {
                _ = try await store.effectiveTextInBackground(of: profile.id)
            } catch {
                if !Task.isCancelled { routingReplayError = store.message(for: error) }
            }
        }
    }

    /// The stopped core won't rebuild the invalidated config for us. Refresh its conflict report
    /// while this tab is visible, and retry for the new layer if the user switches rules again.
    private var layerNeedingReplay: RoutingLayer? {
        guard profile.id == store.activeProfileID, store.effective == nil, layer.edits.contains(where: \.enabled) else { return nil }
        return layer
    }

    /// What the chosen rules are, and what the edits below sit on. With the subscription's rules,
    /// what the template would replace them with: choosing it applies at once.
    static func routingNote(template: String?) -> String {
        template == nil
            ? String(localized: "下面的修改在订阅自带的规则之上重新应用。选模板会立即替换这些规则：按地区分组，AI 服务优先走美国，国内网站和苹果服务直连，拦截广告。")
            : String(localized: "按地区分组，AI 服务优先走美国，国内网站和苹果服务直连，拦截广告。下面的修改在模板之上重新应用。")
    }

    @ViewBuilder private var edits: some View {
        if layer.edits.isEmpty {
            StateView(symbol: "arrow.triangle.branch", title: String(localized: "还没有修改"),
                      message: String(localized: "在 Agent 里说一句话（比如“Netflix 走日本”），应用后的修改会记在这里，订阅更新后自动重新应用。"))
        } else {
            List {
                ForEach(layer.edits.reversed()) { edit in
                    EditRow(edit: edit, conflicts: conflicts(of: edit.id),
                            setEnabled: { store.setEdit(edit.id, enabled: $0, in: profile.id); reload() },
                            delete: { store.deleteEdit(edit.id, in: profile.id); reload() })
                }
            }
            .listStyle(.bordered)
        }
    }

    /// Why parts of an edit did not apply, for the profile in use.
    private func conflicts(of id: UUID) -> [String] {
        guard profile.id == store.activeProfileID, let result = store.effective?.replay?.edits.first(where: { $0.id == id }) else { return [] }
        return result.items.compactMap { if case .conflict(let reason) = $0.outcome { reason } else { nil } }
    }

    private func reload() {
        nodes = store.nodeNames(of: profile.id)
        layer = store.layer(of: profile.id)
    }
}

private struct EditRow: View {
    let edit: RoutingLayer.Edit
    let conflicts: [String]
    let setEnabled: (Bool) -> Void
    let delete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Toggle("启用", isOn: Binding(get: { edit.enabled }, set: setEnabled)).accentCheckbox().labelsHidden()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(edit.prompt).lineLimit(2)
                HStack(spacing: Spacing.xs) {
                    Tag(text: edit.source.label)
                    Text(Format.relative(edit.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(conflicts.uniqued(), id: \.self) { StatusBadge(kind: .warning, text: $0) }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("删除这项修改")
                .accessibilityLabel(String(localized: "删除这项修改"))
        }
        .opacity(edit.enabled ? 1 : 0.6)
        // Asked each time: it can't be undone, and unchecking the box is there to set one aside.
        .alert("删除这项修改？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这项修改会从“我的分流”里删除，无法撤销。只想暂时不用的话，取消勾选就可以。")
        }
    }
}

extension RoutingLayer.Edit.Source {
    var label: String {
        switch self {
        case .agent: String(localized: "Agent")
        case .manual: String(localized: "手动")
        case .healthCheck: String(localized: "配置体检")
        case .template: String(localized: "模板")
        }
    }
}

/// Saving a profile as the core runs it, with "my routing" merged in.
enum ConfigExport {
    static func run(_ profile: Profile, store: ProxyStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        panel.nameFieldStringValue = "\(profile.name).yaml"
        panel.message = String(localized: "导出的配置包含“我的分流”的修改，不含控制器地址和密钥。")
        let overrides = NSButton(checkboxWithTitle: String(localized: "包含 Veer 的覆写（端口、DNS、TUN）"), target: nil, action: nil)
        overrides.state = .off
        // Inside a padded container: a bare checkbox sits on the panel's separator line.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: overrides.fittingSize.width + 40, height: overrides.fittingSize.height + 24))
        overrides.frame.origin = NSPoint(x: 20, y: 12)
        accessory.addSubview(overrides)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try store.exportText(of: profile.id, withOverrides: overrides.state == .on)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            BackupFlow.show(error)
        }
    }
}

/// One field for a subscription link or pasted content, or a file.
struct ImportForm: View {
    @Environment(ProxyStore.self) private var store
    @State private var choosingFile = false
    /// Shown beside Import in the sheet; onboarding has no cancel.
    var cancel: (() -> Void)?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Spacing.lg) {
            TextEditor(text: $store.importText)
                .font(Typography.code)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color.separatorLine))
                .frame(height: 160)
                .accessibilityLabel(String(localized: "订阅链接或配置内容"))
            if let error = store.importError {
                StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("选择文件…") { choosingFile = true }.neutralControl()
                Button("从剪贴板粘贴") { store.importText = NSPasteboard.general.string(forType: .string) ?? "" }.neutralControl()
                Spacer()
                if store.importing { ProgressView().controlSize(.small) }
                if let cancel { Button("取消", action: cancel).keyboardShortcut(.cancelAction).neutralControl() }
                Button("导入") { store.importFromText() }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction(.regular)
                    .disabled(store.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.importing)
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            if case .success(let url) = result { store.importFile(url) }
        }
    }
}

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("导入配置").font(.title3.weight(.semibold))
                Text("粘贴订阅链接、Mihomo / Clash 配置、Base64 订阅内容或节点分享链接。订阅链接只保存在这台 Mac 上（仅你可读），用于之后更新。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ImportForm(cancel: { dismiss() })
        }
        .padding(Spacing.xl)
        .frame(width: 560)
    }
}

/// The health check of a profile as it runs: problems certain from the config itself, worst
/// first. Safe fixes go into "my routing"; the rest can go to the Agent.
private struct ConfigCheckList: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let done: () -> Void
    @State private var findings: [HealthFinding]?
    @State private var fixing: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error { StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true) }
            if let findings {
                if findings.isEmpty {
                    StateView(symbol: "checkmark.seal", title: String(localized: "没有发现问题"),
                              message: String(localized: "体检只报告从配置本身就能确定的问题，比如永远不会命中的规则、引用不存在的出口。"))
                } else {
                    List(findings) { row($0) }.listStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { findings = await store.healthFindings(of: profile.id) }
    }

    private func row(_ finding: HealthFinding) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: Self.kind(finding.severity), text: finding.title, compact: true)
                Spacer()
                if fixing == finding.id { ProgressView().controlSize(.small) }
                if !finding.fix.isEmpty, let title = finding.fixTitle {
                    Button(title) { fix(finding) }.secondaryAction().disabled(fixing != nil)
                } else if let instruction = finding.aiInstruction {
                    Button(String(localized: "问 Agent")) {
                        dismiss()
                        agent.open(asking: instruction)
                    }
                    .secondaryAction()
                }
            }
            Text(verbatim: finding.subject).font(Typography.codeSmall).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Text(finding.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let hint = finding.hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func fix(_ finding: HealthFinding) {
        fixing = finding.id
        error = nil
        Task {
            defer { fixing = nil }
            do {
                try await store.applyFix(finding, in: profile.id)
                findings = await store.healthFindings(of: profile.id)
                done()
            } catch {
                self.error = store.message(for: error)
            }
        }
    }

    static func kind(_ severity: HealthFinding.Severity) -> StatusKind {
        switch severity {
        case .error: .failure
        case .warning: .warning
        case .notice: .info
        }
    }
}
