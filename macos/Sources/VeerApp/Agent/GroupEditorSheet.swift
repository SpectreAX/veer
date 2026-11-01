import SwiftUI
import VeerCore

/// Edits a group's members (add, remove, reorder): a new group from a pending review card, also
/// its name and type; or an existing group of the draft, only its members.
struct GroupEditorSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: GroupEditTarget?
    /// The existing group being edited, by name.
    let existing: String?

    init(target: GroupEditTarget) {
        self.target = target
        existing = nil
    }

    init(existing name: String) {
        target = nil
        existing = name
    }
    @State private var name = ""
    @State private var type = "select"
    @State private var members: [String] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var selectedMember: String?

    private var group: ChangeItem.GroupInfo? {
        if let existing, let draft = store.draft, let found = draft.target(named: existing) {
            return .init(name: existing, type: found.type ?? "select", members: draft.groupMembers[existing] ?? [], regionCounts: [:])
        }
        guard let target else { return nil }
        return store.current?.turns.first { $0.id == target.turnID }?.proposal?.items.first { $0.id == target.itemID }?.group
    }

    private var candidates: [Target] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (store.draft?.targets ?? []).filter { target in
            !members.contains(target.name) && target.name != existing && (query.isEmpty || target.name.lowercased().contains(query))
        }
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "名称不能为空") }
        if trimmed.contains(",") || trimmed.count > 64 { return String(localized: "名称不能包含逗号，最多 64 个字符") }
        if store.draft?.targets.contains(where: { $0.name == trimmed }) == true { return String(localized: "已有同名的策略组或节点，保存后会自动加序号") }
        return nil
    }

    private func move(_ member: String, by offset: Int) {
        guard let index = members.firstIndex(of: member) else { return }
        let destination = index + offset
        guard members.indices.contains(destination) else { return }
        members.swapAt(index, destination)
    }

    private func remove(_ member: String) {
        members.removeAll { $0 == member }
        if selectedMember == member { selectedMember = nil }
    }

    var body: some View {
        let regions = store.regions
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if let existing {
                HStack(spacing: Spacing.sm) {
                    Text(String(localized: "编辑“\(existing)”的成员")).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Tag(text: ProfileAnalysis.groupTypeTitle(type))
                }
            } else {
                Text(String(localized: "编辑新策略组")).font(.title3.weight(.semibold))
            }
            if existing == nil { Form {
                TextField(String(localized: "名称"), text: $name)
                if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(Color.statusWarning) }
                Picker(String(localized: "类型"), selection: $type) {
                    Text(ProfileAnalysis.groupTypeTitle("select")).tag("select")
                    Text(ProfileAnalysis.groupTypeTitle("url-test")).tag("url-test")
                    Text(ProfileAnalysis.groupTypeTitle("fallback")).tag("fallback")
                }
                .neutralControl()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 118)
            }

            HStack(alignment: .top, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(String(localized: "成员（\(members.count)）")).font(.headline)
                    List(selection: $selectedMember) {
                        ForEach(members, id: \.self) { member in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                                ExitLabel(name: member, region: regions[member])
                                Spacer()
                                Button { remove(member) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).neutralControl()
                                    .help(String(localized: "移除")).accessibilityLabel(String(localized: "移除 \(member)"))
                            }
                            .listRowSeparator(.hidden)
                            .tag(member)
                            .contextMenu {
                                Button(String(localized: "上移")) { move(member, by: -1) }.disabled(members.first == member)
                                Button(String(localized: "下移")) { move(member, by: 1) }.disabled(members.last == member)
                                Divider()
                                Button(String(localized: "移除")) { remove(member) }
                            }
                            // Drag is not available to VoiceOver or the keyboard; these are.
                            .accessibilityAction(named: String(localized: "上移")) { move(member, by: -1) }
                            .accessibilityAction(named: String(localized: "下移")) { move(member, by: 1) }
                        }
                        .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.bordered)
                    .onKeyPress(.upArrow, phases: .down) { press in
                        guard press.modifiers.contains(.option), let member = selectedMember else { return .ignored }
                        move(member, by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: .down) { press in
                        guard press.modifiers.contains(.option), let member = selectedMember else { return .ignored }
                        move(member, by: 1)
                        return .handled
                    }
                    .onDeleteCommand { if let member = selectedMember { remove(member) } }
                    Text(String(localized: "拖动排序，或选中后按 ⌥↑ / ⌥↓；右键可上移、下移")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(String(localized: "添加")).font(.headline)
                    TextField(String(localized: "搜索出口"), text: $search).textFieldStyle(.roundedBorder)
                    if candidates.isEmpty {
                        Text(search.isEmpty ? String(localized: "所有出口都已加入") : String(localized: "没有匹配“\(search)”的出口"))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: Spacing.xxxl)
                    }
                    List(candidates) { target in
                        Button { members.append(target.name) } label: {
                            HStack {
                                ExitLabel(name: target.name, region: target.kind == .builtin ? nil : regions[target.name], kind: target.kind)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Color.veerAccent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 300)

            HStack {
                Text(existing == nil ? String(localized: "只修改这个新策略组；已有策略组不会改变。保存后会重新生成并校验。")
                                     : String(localized: "只改这个策略组的成员，其他字段和其他策略组不变。保存后生成一项修改，确认并应用后生效。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(String(localized: "取消")) { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button(existing == nil ? String(localized: "保存") : String(localized: "生成修改")) {
                    if let target {
                        store.editNewGroup(target, name: name, type: type, members: members)
                    } else if let existing {
                        store.editGroupMembers(existing, members: members)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.accentFill)
                .disabled(existing == nil
                    ? members.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains(",")
                    : members == group?.members.uniqued() || (members.isEmpty && group?.members.isEmpty == false))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760, height: 640)
        .onAppear {
            guard !loaded, let group else { return }
            loaded = true
            name = group.name
            type = group.type
            members = group.members.uniqued()
        }
    }
}
