import SwiftUI
import VeerEditor

struct ConversationReviewView: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: EditorLayout.small) {
                    Text("修改审阅").font(.headline)
                    Text(model.reviewedTurn?.state.title ?? "尚无候选").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                UtilityButton(title: "返回对话", symbol: "xmark") { model.review.close() }
            }.padding(EditorLayout.section)
            Divider()
            if let turn = model.reviewedTurn, let preview = turn.preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: EditorLayout.section) {
                        Label(turn.fileName, systemImage: "doc.text").font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text(turn.state.title + " · 未应用代理").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("流量出口").font(.headline)
                        ForEach(routingReviewGroups(preview.summaries)) { group in
                            VStack(alignment: .leading, spacing: EditorLayout.small) {
                                Text(group.id.service).fontWeight(.semibold)
                                Label(group.id.kind == "remove_rule" ? "删除规则" : group.id.target ?? "未知出口", systemImage: "arrow.right")
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                if let destination = turn.groups.first(where: { $0.name == group.id.target }) {
                                    Text((declaredRegions.first { $0.0 == destination.region }?.1 ?? destination.region) + " · 未实测")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("\(group.changes.count) 条规则 · 匹配范围", isExpanded: Binding(
                                    get: { turn.expandedRoutes.contains(group.id) },
                                    set: { model.setRouteDisclosure(turn.id, group: group.id, expanded: $0) }
                                )) {
                                    ForEach(Array(group.changes.enumerated()), id: \.offset) { _, change in
                                        Text("\(change.matchType),\(change.match) → \(change.target ?? "删除")")
                                            .font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.font(.caption)
                            }.padding(.bottom, EditorLayout.small)
                        }
                        ConversationDiffView(model: model, turn: turn)
                        ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Label(preview.validation.message, systemImage: preview.validation.status == "failed" ? "exclamationmark.triangle" : "checkmark.shield")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("出口地区与实际可达性未验证。尚未应用到代理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(EditorLayout.section).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Text(turn.state == .pending ? "确认前草稿不变" : turn.state.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if turn.state == .pending {
                        Button("放弃") { model.discardTurn(turn.id) }.modifier(GlassUtilityAction()).disabled(!model.canConfirmTurn(turn.id))
                        Button("确认修改") { model.confirmTurn(turn.id) }.modifier(GlassAction()).disabled(!model.canConfirmTurn(turn.id))
                    } else if turn.state == .confirmed {
                        Button("撤销此修改") { model.undoTurn(turn.id) }.modifier(GlassUtilityAction()).disabled(!model.canUndoTurn(turn.id))
                            .help("仅撤销当前快照栈顶操作；较早修改请依序撤销。")
                    }
                }.padding(EditorLayout.section)
            } else {
                Spacer()
                ContentUnavailableView("尚无修改候选", systemImage: "doc.text.magnifyingglass", description: Text("发送分流指令后，点击文件条目审阅出口与规则差异。"))
                Spacer()
            }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
    }
}

struct ConversationDiffView: View {
    @Bindable var model: EditorModel
    let turn: ConversationTurn
    var body: some View {
        VStack(alignment: .leading, spacing: EditorLayout.small) {
            HStack {
                Text("YAML Diff").font(.headline)
                Spacer()
                Button("复制 Diff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.diffLines.map { row in
                        (row.kind == "add" ? "+ " : row.kind == "remove" ? "− " : "  ") + row.text
                    }.joined(separator: "\n"), forType: .string)
                    model.status = "已复制规则 Diff。"
                }.buttonStyle(.borderless)
            }
            Text("− 删除 / + 新增").font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(turn.diffLines) { row in
                        HStack(spacing: EditorLayout.small) {
                            Text(row.before.map(String.init) ?? "").frame(width: WorkbenchStyle.diffNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
                            Text(row.after.map(String.init) ?? "").frame(width: WorkbenchStyle.diffNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
                            Text((row.kind == "add" ? "+ " : row.kind == "remove" ? "− " : "  ") + row.text)
                                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                        }.font(.callout.monospaced()).padding(EditorLayout.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.kind == "add" ? Color.green.opacity(0.08) : row.kind == "remove" ? Color.red.opacity(0.08) : Color.clear)
                    }
                }
            }.frame(height: EditorLayout.editorHeight)
        }
    }
}
