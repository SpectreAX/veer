import AppKit
import VeerEditor

/// Everything one saved session needs to resume: the imported source, draft with
/// undo history, and the conversation. Encrypted by `SessionStore` on disk.
nonisolated struct SessionState: Codable {
    var name: String
    var source: String
    var draft: DraftSession
    var conversation: [ConversationTurn]
}

// MARK: - Sessions

extension EditorModel {
    var filteredSessions: [StoredSession] {
        let query = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.name.lowercased().contains(query) || $0.subtitle.lowercased().contains(query) }
    }

    /// Read saved sessions once at launch and resume the most recent one.
    func loadSessions() {
        guard let store, sessions.isEmpty, activeSessionID == nil else { return }
        do {
            sessions = try store.load().sorted { $0.updatedAt > $1.updatedAt }
            if let first = sessions.first { activate(first) }
        } catch {
            let aside = try? store.quarantine()
            storeMessage = error.localizedDescription + (aside.map { " 已移到 \($0.lastPathComponent)。" } ?? "")
        }
    }

    func switchSession(_ id: UUID) {
        guard id != activeSessionID else { section = .editor; return }
        guard !busy else { status = "请先等待或取消当前处理，再切换会话。"; return }
        guard let target = sessions.first(where: { $0.id == id }) else { return }
        stashActiveSession()
        activate(target)
        section = .editor
        scheduleSave()
    }

    func deleteSession(_ id: UUID) {
        guard !busy || id != activeSessionID, let target = sessions.first(where: { $0.id == id }) else { return }
        if target.hasUnexportedChanges || (id == activeSessionID && session.hasUnsavedChanges) {
            let alert = NSAlert()
            alert.messageText = "删除“\(target.name)”？"
            alert.informativeText = "此会话有未导出的修改。删除后对话、草稿与撤销记录都无法恢复。原配置文件不受影响。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "删除")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        sessions.removeAll { $0.id == id }
        if id == activeSessionID {
            activeSessionID = nil
            if let next = sessions.first { activate(next) } else { clearDocument() }
        }
        scheduleSave()
        status = "会话已删除。"
    }

    /// Write the active session's current state into `sessions`.
    func stashActiveSession() {
        guard let id = activeSessionID, let source = importedSource else { return }
        let state = SessionState(name: importedName, source: source, draft: session, conversation: conversation)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let subtitle = conversation.last?.prompt ?? "\(session.draft.groups.count) 个出口"
        let record = StoredSession(id: id, name: importedName, subtitle: subtitle, hasUnexportedChanges: session.hasUnsavedChanges, updatedAt: Date(), state: data)
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = record } else { sessions.insert(record, at: 0) }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Debounced encrypted save. Without a store, sessions live only in memory.
    func scheduleSave() {
        stashActiveSession()
        guard let store else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.write(store)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        stashActiveSession()
        if let store { write(store) }
    }

    private func write(_ store: SessionStore) {
        do { try store.save(sessions); storeMessage = nil }
        catch { storeMessage = "会话未能保存：\(error.localizedDescription)" }
    }

    private func activate(_ record: StoredSession) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: record.state) else {
            storeMessage = "“\(record.name)”无法读取，已跳过。"
            return
        }
        activeSessionID = record.id
        importedSource = state.source; importedName = state.name; importedFileURL = nil
        session = state.draft
        conversation = state.conversation.map { var turn = $0; turn.restoreAfterRelaunch(); return turn }
        resetWorkspace()
    }

    private func clearDocument() {
        importedSource = nil; importedName = ""; importedFileURL = nil
        session = DraftSession(); conversation = []
        resetWorkspace()
    }

    private func resetWorkspace() {
        activeTurn = conversation.last(where: { $0.state == .pending })?.id
        prompt = ""; completion = nil
        conversationScroll = ConversationScrollState(); review = ConversationReviewState()
        ruleCount = nil; ruleList = nil; candidateRuleList = nil; ruleFilter = ""; testDomain = ""; testedDomain = ""
        issue = nil; isError = false
    }
}

// MARK: - Per-card approval

extension EditorModel {
    func setRoute(_ group: RoutingReviewGroup.ID, accepted: Bool, in id: UUID) {
        guard canConfirmTurn(id) else { return }
        updateTurn(id) { if accepted { $0.rejectedRoutes.remove(group) } else { $0.rejectedRoutes.insert(group) } }
        candidateRuleList = nil
    }

    /// Write only the accepted cards. All accepted uses the existing candidate; a
    /// subset is re-applied and re-validated by the service before it reaches the draft.
    func applyTurn(_ id: UUID) {
        guard canConfirmTurn(id), let turn = conversation.first(where: { $0.id == id }), let preview = turn.preview else { return }
        guard turn.acceptedRouteCount > 0 else { return }
        if turn.rejectedRoutes.isEmpty { confirm(); return }
        guard let plan = preview.plan, plan.operations.count == preview.summaries.count else {
            status = "当前编辑服务不支持部分写入。请重新启动应用后重试。"; isError = true; return
        }
        let operations = zip(plan.operations, preview.summaries).filter { !turn.rejectedRoutes.contains(routingGroupID($0.1)) }.map(\.0)
        let draft = session.draft, revision = session.revision
        perform("正在写入已接受的修改…") {
            let result = try await self.client.apply(draft, plan: EditPlan(operations: operations), source: self.importedSource)
            try self.requireCurrent(revision)
            guard result.validation.status != "failed" else { throw EditorFailure("已接受的修改没有通过校验，未写入。" + result.validation.message) }
            guard self.session.receive(result, revision: revision), self.session.confirm() else { throw EditorFailure("草稿已变化，未写入。请重新生成。") }
            let token = self.session.undoToken
            let rejected = turn.routeGroups.count - turn.acceptedRouteCount
            self.updateTurn(id) {
                $0.state = .confirmed; $0.undoToken = token
                $0.diffLines = conversationDiffLines(result.diff)
                $0.message = "已写入 \($0.acceptedRouteCount) 项，拒绝 \(rejected) 项；尚未应用到代理。"
                $0.steps.append("部分写入已重新校验：" + result.validation.message)
            }
            self.ruleCount = nil; self.ruleList = nil
            self.status = "已写入接受的修改，尚未应用到代理。"
            self.scheduleSave()
        }
    }

    func rejectAll(_ id: UUID) {
        guard canConfirmTurn(id) else { return }
        updateTurn(id) { turn in turn.rejectedRoutes = Set(turn.routeGroups.map(\.id)) }
        discard()
    }
}

// MARK: - Inspector

extension EditorModel {
    var filteredRules: [(index: Int, rule: String)] {
        let all = Array((ruleList ?? []).enumerated()).map { (index: $0.offset + 1, rule: $0.element) }
        let query = ruleFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? all : all.filter { $0.rule.lowercased().contains(query) }
    }

    /// Rules added since the last export, by exact rule text.
    func isNewSinceExport(_ rule: String) -> Bool { !session.exportedRules.contains(rule) }

    var pendingTurn: ConversationTurn? {
        guard let turn = reviewedTurn ?? conversation.last, turn.state == .pending else { return nil }
        return turn
    }

    /// Parse the draft (and a pending candidate) through the service so quoting matches YAML exactly.
    func refreshRuleList() {
        guard hasDocument || !session.draft.groups.isEmpty else { return }
        let draft = session.draft, source = importedSource, revision = session.revision
        let candidate = pendingTurn.flatMap { turn in turn.rejectedRoutes.isEmpty ? turn.preview?.candidate : nil }
        inspectTask?.cancel()
        inspectTask = Task {
            do {
                try await self.ensureService()
                let current = try await self.client.inspect(draft, source: source)
                var pending: [String]?
                if let candidate { pending = try await self.client.inspect(Draft(groups: draft.groups, rules: candidate), source: source).rules }
                guard !Task.isCancelled, self.session.revision == revision else { return }
                self.ruleList = current.rules ?? []
                self.candidateRuleList = pending
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.status = "无法读取规则列表：\(error.localizedDescription)"
            }
        }
    }

    func runDomainTest() {
        let domain = testDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }
        testedDomain = domain
        if ruleList == nil || (pendingTurn != nil && candidateRuleList == nil) { refreshRuleList() }
    }

    func openDomainTest(_ domain: String = "") {
        review.show(.test)
        if !domain.isEmpty { testDomain = domain; runDomainTest() } else if ruleList == nil { refreshRuleList() }
    }
}

// MARK: - Composer completion

extension EditorModel {
    /// Called by the text view on every edit or caret move. Never while an IME is composing.
    func updateCompletion(text: String, caret: Int, composing: Bool) {
        guard !composing, let trigger = completionTrigger(in: text, caret: caret) else { completion = nil; return }
        let items = completionItems(for: trigger, groups: session.draft.groups)
        guard !items.isEmpty else { completion = nil; return }
        let index = completion.map { min($0.index, items.count - 1) } ?? 0
        completion = CompletionState(trigger: trigger, items: items, index: index)
    }

    func moveCompletion(by offset: Int) {
        guard var state = completion, !state.items.isEmpty else { return }
        state.index = (state.index + offset + state.items.count) % state.items.count
        completion = state
    }

    func chooseCompletion(_ index: Int? = nil) {
        guard let state = completion else { return }
        let item = state.items[index ?? state.index]
        completion = nil
        if item.opensDomainTest {
            let rest = (prompt as NSString).replacingCharacters(in: state.trigger.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = ""
            openDomainTest(rest.contains(".") ? rest : "")
            return
        }
        let result = applyCompletion(item, to: prompt, trigger: state.trigger)
        prompt = result.text
        pendingCaret = result.caret
    }
}
