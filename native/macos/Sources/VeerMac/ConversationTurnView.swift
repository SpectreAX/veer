import SwiftUI
import VeerEditor

struct ConversationTurnView: View {
    @Bindable var model: EditorModel
    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: EditorLayout.section) {
            HStack {
                Spacer(minLength: WorkbenchStyle.utilitySize)
                Text(turn.prompt).textSelection(.enabled)
                    .padding(EditorLayout.section)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
            }
            DisclosureGroup(isExpanded: Binding(get: { turn.showsSteps }, set: { model.setDisclosure(turn.id, steps: $0) })) {
                VStack(alignment: .leading, spacing: EditorLayout.small) {
                    Text("只显示实际任务状态，不展示模型内部推理。本机服务返回生成与校验结果，不提供实时细分阶段。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, EditorLayout.small)
            } label: {
                HStack(spacing: EditorLayout.small) {
                    if turn.state.isRunning {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in
                            Text("\(turn.mode == "ai" ? "Thinking…" : "正在处理…") \(max(0, Int(context.date.timeIntervalSince(turn.startedAt))))s")
                        }
                    } else {
                        Image(systemName: turn.state == .failed ? "exclamationmark.triangle" : turn.state == .cancelled ? "stop.circle" : "checkmark")
                        Text(turn.state == .failed || turn.state == .cancelled ? turn.state.title : "处理完成 · \(turn.steps.count) 个步骤")
                    }
                }.font(.callout.weight(.medium))
            }
            if !turn.message.isEmpty { Text(turn.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let preview = turn.preview {
                ForEach(routingReviewGroups(preview.summaries)) { group in
                    HStack(alignment: .top, spacing: EditorLayout.small) {
                        Text(group.id.service).fontWeight(.semibold)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(group.id.kind == "remove_rule" ? "删除规则" : group.id.target ?? "未知出口")
                            .fixedSize(horizontal: false, vertical: true)
                    }.textSelection(.enabled)
                }
                Button { model.openReview(turn.id) } label: {
                    HStack(alignment: .center, spacing: EditorLayout.small) {
                        Label(turn.fileName, systemImage: "doc.text")
                            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: EditorLayout.small)
                        Text(turn.state.title).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(EditorLayout.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
                        .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                        .contentShape(RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
                }.buttonStyle(.plain).accessibilityLabel("审阅 \(turn.fileName)，\(turn.state.title)")
                Text("地区与网络可达性未验证。尚未应用到代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if turn.state == .failed || turn.state == .cancelled {
                Button("重新生成") { model.prompt = turn.prompt; model.mode = turn.mode; model.generate() }
                    .modifier(GlassUtilityAction()).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
