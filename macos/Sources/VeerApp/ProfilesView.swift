import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeerProxy

/// Profiles: which one runs, updating subscriptions, importing and removing.
struct ProfilesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var pendingDeletion: Profile?
    @State private var details: Profile?

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                StateView(symbol: "tray.and.arrow.down", title: String(localized: "还没有配置"),
                          message: String(localized: "支持订阅链接、Mihomo / Clash 配置文件、Base64 订阅内容和节点分享链接。"),
                          actionTitle: String(localized: "导入配置…")) { store.openImport() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
                        if let effective = store.effective { EffectiveWarnings(effective: effective) }
                        ForEach(store.profiles) { profile in
                            ProfileRow(profile: profile, active: profile.id == store.activeProfileID,
                                       showDetails: { details = profile }, delete: { pendingDeletion = profile })
                        }
                    }
                    .padding(Spacing.xl)
                    .frame(maxWidth: Metrics.readingWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.openImport() } label: { Label("导入配置", systemImage: "plus") }.help("导入配置（⌘O）")
            }
        }
        .sheet(item: $details) { ProfileDetailSheet(profile: $0) }
        .alert("删除配置？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) { if let profile = pendingDeletion { store.delete(profile.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDeletion?.id == store.activeProfileID
                 ? String(localized: "这是正在使用的配置，删除后内核会停止。")
                 : String(localized: "配置文件、订阅链接和“我的分流”会从本机删除。"))
        }
    }
}

/// What the layer could not do for the profile in use.
private struct EffectiveWarnings: View {
    let effective: EffectiveConfig

    var body: some View {
        if effective.conflictCount > 0 {
            StatusBadge(kind: .warning, text: String(localized: "“我的分流”里有 \(effective.conflictCount) 项修改未能用到更新后的订阅上，打开“节点与分流”查看原因。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        if !effective.emptiedGroups.isEmpty {
            let groups = effective.emptiedGroups.formatted(.list(type: .and))
            StatusBadge(kind: .warning, text: String(localized: "取消勾选节点后，这些策略组没有节点了，暂时改为直连：\(groups)"))
                .fixedSize(horizontal: false, vertical: true)
        }
        if !effective.keptNodes.isEmpty {
            let nodes = effective.keptNodes.formatted(.list(type: .and))
            StatusBadge(kind: .info, text: String(localized: "有规则直接使用这些节点，所以它们没有被去掉：\(nodes)"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProfileRow: View {
    @Environment(ProxyStore.self) private var store
    let profile: Profile
    let active: Bool
    let showDetails: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button { store.activate(profile.id) } label: {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? Color.veerAccent : Color.secondary)
                    .font(.title3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(active)
            .help(active ? String(localized: "正在使用这个配置") : String(localized: "使用这个配置"))
            .accessibilityLabel(active ? String(localized: "正在使用这个配置") : String(localized: "使用这个配置"))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Tag(text: profile.isSubscription ? String(localized: "订阅") : String(localized: "本地"))
                    if active { Tag(text: String(localized: "使用中"), tint: .statusSuccess) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            if store.updatingProfiles.contains(profile.id) { ProgressView().controlSize(.small) }
            if profile.isSubscription {
                Button("更新") { store.update(profile.id) }
                    .secondaryAction()
                    .disabled(store.updatingProfiles.contains(profile.id))
            }
            if !active {
                Button("使用") { store.activate(profile.id) }.secondaryAction()
            }
            Menu {
                Button("节点与分流…", action: showDetails)
                Button("导出配置…") { ConfigExport.run(profile, store: store) }
                Divider()
                Button("删除…", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
            .accessibilityLabel(String(localized: "更多操作"))
        }
        .panel(padding: Spacing.md)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: showDetails)
    }

    private var detail: String {
        var parts = [String(localized: "\(profile.nodeCount) 个节点"), String(localized: "更新于 \(Format.relative(profile.updatedAt))")]
        if let usage = profile.usage, let total = usage.total, total > 0 {
            let used = (usage.upload ?? 0) + (usage.download ?? 0)
            let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
            parts.append(String(localized: "已用 \(usedText) / \(totalText)"))
        }
        return parts.joined(separator: " · ")
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

    enum Tab: Hashable { case nodes, routing }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text(profile.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                SegmentedControl(label: String(localized: "显示"), selection: $tab, options: [
                    .init(value: .nodes, title: String(localized: "节点")),
                    .init(value: .routing, title: String(localized: "我的分流")),
                ])
                .fixedSize()
            }
            switch tab {
            case .nodes: nodeList
            case .routing: routingList
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction(.regular)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 520)
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
                    Toggle(isOn: Binding(get: { !layer.excludedNodes.contains(name) }, set: { included in
                        store.setNode(name, included: included, in: profile.id)
                        reload()
                    })) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var routingList: some View {
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

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Toggle("启用", isOn: Binding(get: { edit.enabled }, set: setEnabled)).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(edit.prompt).lineLimit(2)
                HStack(spacing: Spacing.xs) {
                    Tag(text: edit.source.label)
                    Text(Format.relative(edit.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(conflicts, id: \.self) { StatusBadge(kind: .warning, text: $0, compact: true) }
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("删除这项修改")
        }
        .opacity(edit.enabled ? 1 : 0.6)
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
            store.notice = String(localized: "导出失败：\(store.message(for: error))")
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
