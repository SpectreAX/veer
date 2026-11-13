import SwiftUI
import VeerEditor

/// Right-hand inspector: the selected turn's changes, the full rule list, and an offline domain test.
struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: EditorLayout.small) {
                Picker("检查器内容", selection: $model.review.tab) {
                    ForEach(ConversationReviewState.Tab.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                UtilityButton(title: "关闭检查器（⌘I）", symbol: "xmark") { model.review.close() }
            }.padding(.horizontal, EditorLayout.section).padding(.vertical, EditorLayout.small)
            Divider()
            switch model.review.tab {
            case .changes: changesTab
            case .rules: rulesTab
            case .test: testTab
            }
            Divider()
            HStack {
                Text(model.hasDocument ? "导出完整配置副本，原文件不会被覆盖。" : "导出 rules 片段，不是完整配置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { model.requestExport() } label: { Label("导出…", systemImage: "square.and.arrow.up") }
                    .modifier(GlassUtilityAction()).disabled(model.busy)
            }.padding(EditorLayout.section)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        .onChange(of: model.review.tab, initial: true) { _, tab in
            if tab != .changes, model.ruleList == nil { model.refreshRuleList() }
        }
        .onChange(of: model.session.revision) { _, _ in
            if model.review.tab != .changes { model.refreshRuleList() }
        }
    }

    // MARK: Changes

    @ViewBuilder private var changesTab: some View {
        if let turn = model.reviewedTurn, let preview = turn.preview {
            ScrollView {
                VStack(alignment: .leading, spacing: EditorLayout.section) {
                    HStack {
                        Text("第 \((model.conversation.firstIndex { $0.id == turn.id } ?? 0) + 1) 轮 · \(turn.state.title)").font(.headline)
                        Spacer()
                        LineChangeBadge(count: lineChangeCount(turn.diffLines))
                    }
                    Text(turn.state == .pending && !turn.rejectedRoutes.isEmpty
                         ? "Diff 显示完整候选；写入时只应用已接受的卡片，并由服务重新校验。"
                         : "仅修改 rules；其他字段逐字节保留。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(turn.routeGroups) { group in
                        HStack(alignment: .firstTextBaseline, spacing: EditorLayout.small) {
                            Text(group.id.service).fontWeight(.semibold)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).imageScale(.small)
                            Text(group.id.kind == "remove_rule" ? "删除规则" : group.id.target ?? "未知出口")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: EditorLayout.small)
                            if turn.rejectedRoutes.contains(group.id) { Text("已拒绝").font(.caption).foregroundStyle(.secondary) }
                        }.textSelection(.enabled)
                    }
                    ConversationDiffView(model: model, turn: turn)
                    ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ValidationLabel(validation: preview.validation)
                    Text("出口地区与实际可达性未验证。尚未应用到代理。").font(.caption).foregroundStyle(.secondary)
                }.padding(EditorLayout.section).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Spacer()
            ContentUnavailableView("尚无修改", systemImage: "doc.text.magnifyingglass", description: Text("发送一条分流指令后，在这里查看规则差异。"))
            Spacer()
        }
    }

    // MARK: Rules

    @ViewBuilder private var rulesTab: some View {
        VStack(alignment: .leading, spacing: EditorLayout.small) {
            TextField("筛选规则，例如 netflix 或 DIRECT", text: $model.ruleFilter).textFieldStyle(.roundedBorder)
            HStack {
                Text("当前草稿 · \(model.ruleList?.count ?? 0) 条").font(.headline)
                Spacer()
                if model.session.hasUnsavedChanges {
                    Text("有未导出的修改").font(.caption).foregroundStyle(.orange)
                    LineChangeBadge(count: model.unexportedChanges)
                } else {
                    Text("与上次导出一致").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(EditorLayout.section)
        if model.ruleList == nil {
            Spacer(); ProgressView("正在读取规则…").controlSize(.small); Spacer()
        } else if model.filteredRules.isEmpty {
            Spacer()
            ContentUnavailableView.search(text: model.ruleFilter)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredRules, id: \.index) { row in
                        HStack(alignment: .firstTextBaseline, spacing: EditorLayout.small) {
                            Text("\(row.index)").foregroundStyle(.secondary).frame(width: WorkbenchStyle.diffNumberWidth, alignment: .trailing)
                            Text(row.rule).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout.monospaced())
                        .padding(.vertical, 2).padding(.horizontal, EditorLayout.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.isNewSinceExport(row.rule) ? Color.green.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(model.isNewSinceExport(row.rule) ? "上次导出后新增" : "")
                    }
                }.padding(.horizontal, EditorLayout.section)
                Text("绿色底色为上次导出后新增的规则。规则按顺序匹配，第一条命中即生效。")
                    .font(.caption).foregroundStyle(.secondary).padding(EditorLayout.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Test

    @ViewBuilder private var testTab: some View {
        VStack(alignment: .leading, spacing: EditorLayout.section) {
            HStack {
                TextField("输入域名，例如 www.netflix.com", text: $model.testDomain).textFieldStyle(.roundedBorder)
                    .onSubmit { model.runDomainTest() }
                Button("测试") { model.runDomainTest() }.modifier(GlassAction())
                    .disabled(model.testDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.testedDomain.isEmpty {
                Spacer()
                ContentUnavailableView("测试域名", systemImage: "scope", description: Text("检查一个域名会命中哪条规则、走哪个出口。只在本机计算，不访问网络。"))
                Spacer()
            } else if let rules = model.ruleList {
                ScrollView {
                    VStack(alignment: .leading, spacing: EditorLayout.small) {
                        MatchResultView(title: "当前草稿", match: RuleMatcher.match(rules: rules, domain: model.testedDomain))
                        if let pending = model.pendingTurn, let candidate = model.candidateRuleList {
                            MatchResultView(title: "写入第 \((model.conversation.firstIndex { $0.id == pending.id } ?? 0) + 1) 轮全部修改后", match: RuleMatcher.match(rules: candidate, domain: model.testedDomain))
                        }
                    }
                }
            } else {
                Spacer(); ProgressView("正在读取规则…").controlSize(.small); Spacer()
            }
        }.padding(EditorLayout.section)
    }
}

private struct MatchResultView: View {
    let title: String
    let match: RuleMatch?
    var body: some View {
        VStack(alignment: .leading, spacing: EditorLayout.small) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let match {
                HStack(spacing: EditorLayout.small) {
                    Text(match.domain)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(match.target ?? "未命中").fontWeight(.semibold)
                }.font(.title3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let index = match.index, let rule = match.rule {
                    Text("命中第 \(index) 条：\(rule)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !match.skipped.isEmpty {
                    Text("跳过 \(match.skipped.count) 条需要内核数据或 DNS 的规则（\(match.skipped.map { $0.split(separator: ",").prefix(2).joined(separator: ",") }.joined(separator: "、"))）。实际结果可能更早命中它们。")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("请输入有效域名，例如 www.netflix.com。", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }.padding(EditorLayout.section).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
            .accessibilityElement(children: .combine)
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
