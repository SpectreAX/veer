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
                        Image(systemName: statusSymbol)
                        Text([.failed, .cancelled, .clarify].contains(turn.state) ? turn.state.title : "处理完成 · \(turn.steps.count) 个步骤")
                    }
                }.font(.callout.weight(.medium))
            }
            if turn.state == .clarify {
                // The status row above already carries the question symbol.
                VStack(alignment: .leading, spacing: EditorLayout.small) {
                    Text(turn.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("在下方回复，说明服务与出口地区。草稿没有变化。").font(.caption).foregroundStyle(.secondary)
                }
            } else if !turn.message.isEmpty {
                Text(turn.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let preview = turn.preview {
                VStack(spacing: EditorLayout.small) {
                    ForEach(turn.routeGroups) { group in ApprovalCard(model: model, turn: turn, group: group) }
                }
                ValidationLabel(validation: preview.validation)
                HStack(spacing: EditorLayout.small) {
                    if turn.state == .pending {
                        let accepted = turn.acceptedRouteCount
                        Button(accepted > 0 ? "写入 \(accepted) 项到草稿" : "没有接受的修改") { model.applyTurn(turn.id) }
                            .modifier(GlassAction()).disabled(accepted == 0 || !model.canConfirmTurn(turn.id))
                        Button("全部拒绝") { model.rejectAll(turn.id) }
                            .modifier(GlassUtilityAction()).disabled(!model.canConfirmTurn(turn.id))
                    } else if turn.state == .confirmed {
                        Button("撤销写入") { model.undoTurn(turn.id) }
                            .modifier(GlassUtilityAction()).disabled(!model.canUndoTurn(turn.id))
                            .help("只能撤销最近一次写入；较早的修改请依序撤销。")
                    }
                    Spacer(minLength: EditorLayout.small)
                    Button { model.openReview(turn.id) } label: {
                        HStack(spacing: 4) { Text("在检查器中查看 Diff"); LineChangeBadge(count: lineChangeCount(turn.diffLines)) }
                    }.buttonStyle(.borderless).font(.caption)
                }
                Text("地区来自组名推断，未实测；不代表网络可达或服务解锁。尚未应用到代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if turn.state == .failed || turn.state == .cancelled {
                Button("重新生成") { model.prompt = turn.prompt; model.mode = turn.mode; model.generate() }
                    .modifier(GlassUtilityAction()).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSymbol: String {
        switch turn.state {
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        case .clarify: "questionmark.circle"
        case .blocked: "xmark.octagon"
        default: "checkmark"
        }
    }
}

/// One service change with its own accept / reject decision while the turn is pending.
struct ApprovalCard: View {
    @Bindable var model: EditorModel
    let turn: ConversationTurn
    let group: RoutingReviewGroup

    private var rejected: Bool { turn.rejectedRoutes.contains(group.id) }
    private var before: [String] { group.changes.flatMap(\.before) }
    private var after: [String] { group.changes.compactMap(\.after) }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorLayout.small) {
            HStack(alignment: .firstTextBaseline, spacing: EditorLayout.small) {
                Text(group.id.kind == "remove_rule" ? "删除" : "路由")
                    .font(.caption).foregroundStyle(group.id.kind == "remove_rule" ? Color.red : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay { Capsule().strokeBorder(Color(nsColor: .separatorColor)) }
                Text(group.id.service).fontWeight(.semibold)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).imageScale(.small)
                Text(group.id.kind == "remove_rule" ? "移除已有规则" : group.id.target ?? "未知出口")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: EditorLayout.small)
                decision
            }.textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(before.enumerated()), id: \.offset) { Text("− " + $0.element).foregroundStyle(.red) }
                ForEach(Array(after.prefix(2).enumerated()), id: \.offset) { Text("+ " + $0.element).foregroundStyle(.green) }
                if after.count > 2 { Text("以及另外 \(after.count - 2) 条").foregroundStyle(.secondary) }
            }.font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            DisclosureGroup("\(group.changes.count) 个域名 · 匹配范围", isExpanded: Binding(
                get: { turn.expandedRoutes.contains(group.id) },
                set: { model.setRouteDisclosure(turn.id, group: group.id, expanded: $0) }
            )) {
                ForEach(group.changes, id: \.match) { Text($0.match).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
            }.font(.caption)
        }
        .padding(EditorLayout.section)
        .opacity(rejected ? 0.6 : 1)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
    }

    @ViewBuilder private var decision: some View {
        if turn.state == .pending {
            Picker("\(group.id.service) 的审批", selection: Binding(
                get: { !rejected },
                set: { model.setRoute(group.id, accepted: $0, in: turn.id) }
            )) {
                Text("接受").tag(true)
                Text("拒绝").tag(false)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(!model.canConfirmTurn(turn.id))
        } else {
            let label: (String, String) = switch turn.state {
            case .confirmed: rejected ? ("已拒绝", "xmark") : ("已写入", "checkmark")
            case .blocked: ("不能写入", "xmark.octagon")
            case .discarded: ("已拒绝", "xmark")
            default: ("未写入", "minus")
            }
            Label(label.0, systemImage: label.1).font(.caption)
                .foregroundStyle(turn.state == .confirmed && !rejected ? Color.green : .secondary)
        }
    }
}
