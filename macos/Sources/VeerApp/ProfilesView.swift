import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeerCore
import VeerProxy

/// The top of the proxies page: every profile as a card, a click from running. It stays there with the
/// core stopped, and scrolls sideways rather than taking room from the nodes below.
struct ProfileBar: View {
    @Environment(ProxyStore.self) private var store
    @State private var pendingDeletion: Profile?
    @State private var details: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(store.profiles) { profile in
                            ProfileTile(profile: profile, active: profile.id == store.activeProfileID,
                                        showDetails: { details = profile }, delete: { pendingDeletion = profile })
                        }
                        Button { store.openImport() } label: {
                            Image(systemName: "plus")
                                .frame(width: 44)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Color.separatorLine))
                        }
                        .buttonStyle(.plain)
                        .help("导入配置（⌘O）")
                        .accessibilityLabel(String(localized: "导入配置"))
                    }
                    // Cards as tall as the tallest: one with usage has a line more.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.xl)
                }
                .onAppear { if let active = store.activeProfileID { reader.scrollTo(active) } }
                .onChange(of: store.activeProfileID) { _, active in if let active { reader.scrollTo(active) } }
            }
            Group {
                if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
                if let effective = store.effective { EffectiveWarnings(effective: effective) }
            }
            .padding(.horizontal, Spacing.xl)
        }
        .padding(.top, Spacing.sm)
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

/// One profile: the card chooses it, as a node's does, and updating and the rest sit beside that.
private struct ProfileTile: View {
    @Environment(ProxyStore.self) private var store
    let profile: Profile
    let active: Bool
    let showDetails: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private var updating: Bool { store.updatingProfiles.contains(profile.id) }

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
        .frame(width: 320)
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
                HStack(spacing: Spacing.xs) {
                    Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Tag(text: profile.isSubscription ? String(localized: "订阅") : String(localized: "本地"))
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
                    .accentCheckbox()
                }
                .listStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var routingList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("规则", selection: Binding(get: { layer.template ?? "" }, set: { value in
                store.setTemplate(value.isEmpty ? nil : value, for: profile.id)
                reload()
            })) {
                Text("订阅自带的规则").tag("")
                Text(RuleTemplate.title(RuleTemplate.standard)).tag(RuleTemplate.standard)
            }
            .fixedSize()
            .neutralControl()
            Text("模板按地区为这份配置的节点分组，并用内核自带的 GEOSITE 和 GEOIP 数据分流：AI 服务优先走美国，国内网站和苹果服务直连，广告拦截。下面的修改在模板之上重新应用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            edits
        }
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
                ForEach(conflicts, id: \.self) { StatusBadge(kind: .warning, text: $0, compact: true) }
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
                    Button(String(localized: "问 AI")) {
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
