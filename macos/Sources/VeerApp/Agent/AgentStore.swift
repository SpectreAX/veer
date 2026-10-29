import AppKit
import Observation
import SwiftUI
import VeerCore
import VeerProxy

/// A new group in a pending proposal that the group editor changes.
struct GroupEditTarget: Identifiable, Equatable {
    let turnID: UUID
    let itemID: Int
    var id: String { "\(turnID)-\(itemID)" }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var undoable = false
}

/// The Agent page: conversations with the AI about the running profile. A written proposal
/// becomes an edit in that profile's "my routing" layer and reaches the core at once; undo turns
/// the edit off again.
@Observable
final class AgentStore {
    var sessions: [Session] = []
    var selectedID: UUID? {
        didSet { if selectedID != oldValue { olderTurnPages = 0; turnBaseline = current?.turns.count ?? 0 } }
    }
    /// Pages of older turns the user asked to see in the current conversation.
    var olderTurnPages = 0
    @ObservationIgnored private var turnBaseline = 0
    var composerText = ""
    var composerFocusToken = 0
    var showingModelPopover = false
    var showingExecutionModePicker = false
    var payloadTurnID: UUID? { didSet { if payloadTurnID == nil { payloadComparing = false } } }
    var payloadComparing = false
    var editingGroup: GroupEditTarget?
    var pendingDeletion: Session?
    var toast: Toast?
    /// Turns whose candidate is being rebuilt after an accept/reject toggle; writing waits.
    var revalidating: Set<UUID> = []

    var settings: AISettings {
        didSet {
            saveSettings()
            if settings.provider != oldValue.provider { keySaved = keyStore.read(for: settings.provider.rawValue) != nil }
        }
    }
    var useAI: Bool { didSet { defaults.set(useAI, forKey: "useAI") } }
    var executionMode: ExecutionMode { didSet { defaults.set(executionMode.rawValue, forKey: "executionMode") } }
    /// Send literal domains/IPs from existing rules to the AI instead of placeholders. Off by default.
    var shareRuleLiterals: Bool { didSet { defaults.set(shareRuleLiterals, forKey: "shareRuleLiterals") } }
    var searchSettings: SearchSettings {
        didSet { if let data = try? JSONEncoder().encode(searchSettings) { defaults.set(data, forKey: "searchSettings") } }
    }
    /// Keys used only for this run when the user chose not to save them, by service.
    private var sessionKeys: [AIProvider: String] = [:]
    var sessionKey: String? {
        get { sessionKeys[settings.provider] }
        set { sessionKeys[settings.provider] = newValue }
    }
    func hasKey(for service: AIProvider) -> Bool {
        sessionKeys[service] != nil || keyStore.read(for: service.rawValue) != nil
    }
    var keySaved: Bool

    let proxy: ProxyStore
    let sessionStore: SessionStore
    let keyStore: KeyStoring
    let engine: EditorEngine
    @ObservationIgnored let defaults: UserDefaults
    private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var documentCache: [(text: String, document: ConfigDocument)] = []
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "veer.thread-save", qos: .utility)
    @ObservationIgnored private var saveWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    init(proxy: ProxyStore, keyStore: KeyStoring? = nil, engine: EditorEngine? = nil, defaults: UserDefaults = .standard, persist: Bool = true) {
        self.proxy = proxy
        sessionStore = SessionStore(directory: proxy.paths.threads)
        self.keyStore = keyStore ?? FileKeyStore(url: proxy.paths.secrets)
        let geo = GeoDataStore.shared
        self.engine = engine ?? EditorEngine(searcher: WebSearchService(geo: geo), lookup: InstructionLookup(geo: geo), checker: DomainChecker(geo: geo))
        self.defaults = defaults
        var settings = AISettings()
        if let data = defaults.data(forKey: "aiSettings"), let saved = try? JSONDecoder().decode(AISettings.self, from: data) { settings = saved }
        self.settings = settings
        useAI = defaults.object(forKey: "useAI") as? Bool ?? true
        executionMode = defaults.string(forKey: "executionMode").flatMap(ExecutionMode.init(rawValue:)) ?? .manual
        shareRuleLiterals = defaults.object(forKey: "shareRuleLiterals") as? Bool ?? false
        searchSettings = defaults.data(forKey: "searchSettings").flatMap { try? JSONDecoder().decode(SearchSettings.self, from: $0) } ?? SearchSettings()
        keySaved = self.keyStore.read(for: settings.provider.rawValue) != nil
        if persist {
            sessions = sessionStore.loadAll().sorted { $0.updatedAt > $1.updatedAt }
            selectedID = sessions.first?.id
            turnBaseline = sessions.first?.turns.count ?? 0
        }
    }

    // MARK: Derived state

    var current: Session? {
        get { sessions.first { $0.id == selectedID } }
        set {
            guard let newValue, let index = sessions.firstIndex(where: { $0.id == newValue.id }) else { return }
            sessions[index] = newValue
            scheduleSave(newValue)
        }
    }

    /// The profile the current conversation edits.
    var profile: Profile? { current?.profileID.flatMap { id in proxy.profiles.first { $0.id == id } } }

    /// The conversation's profile is not the one running: its changes would not reach the core.
    var profileIsInactive: Bool { current?.profileID != nil && current?.profileID != proxy.activeProfileID }

    /// The profile as the core runs it: the subscription with "my routing" applied.
    var liveText: String? { current?.profileID.flatMap { try? proxy.effectiveText(of: $0) } }

    func document(for text: String) -> ConfigDocument? {
        if let index = documentCache.firstIndex(where: { $0.text == text }) {
            let hit = documentCache.remove(at: index)
            documentCache.insert(hit, at: 0)
            return hit.document
        }
        guard let parsed = try? ConfigDocument.parse(text) else { return nil }
        documentCache.insert((text, parsed), at: 0)
        if documentCache.count > 8 { documentCache.removeLast() }
        return parsed
    }

    var draft: ConfigDocument? { current.flatMap { document(for: $0.draftText) } }

    var regions: [String: Region] {
        guard let current, let draft else { return [:] }
        return current.regions(for: draft.targets)
    }

    static let turnPage = 10

    var visibleTurnCount: Int {
        Self.turnPage * (1 + olderTurnPages) + max(0, (current?.turns.count ?? 0) - turnBaseline)
    }

    var isRunning: Bool { current.map { tasks[$0.id] != nil } ?? false }
    var apiKey: String? { sessionKey ?? keyStore.read(for: settings.provider.rawValue) }
    var aiConfigured: Bool { !settings.provider.needsKey || keySaved || sessionKey != nil }
    var effectiveUseAI: Bool { useAI && aiConfigured }
    var latestProposalTurnID: UUID? { current?.turns.last { $0.proposal != nil }?.id }

    /// Cheap value that changes when the conversation needs to scroll (new turn, step, outcome).
    var conversationToken: String {
        guard let turns = current?.turns, let last = turns.last else { return "" }
        let outcome: String
        switch last.outcome {
        case .running: outcome = "running"
        case .proposal(let proposal): outcome = "proposal-\(proposal.status.rawValue)"
        default: outcome = "done"
        }
        return "\(turns.count)-\(last.id)-\(last.steps.map(\.state.rawValue).joined())-\(outcome)"
    }

    // MARK: Conversations

    /// The interface language by name when it is not Chinese, so the AI answers in it.
    static var replyLanguage: String? {
        guard let code = Bundle.main.preferredLocalizations.first, !code.hasPrefix("zh") else { return nil }
        return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// A new conversation about the profile in use.
    func newThread() {
        guard let profile = proxy.activeProfile, let text = try? proxy.effectiveText(of: profile.id) else { return }
        var session = Session(title: String(localized: "新对话"), source: .pasted, text: text)
        session.profileID = profile.id
        session.exitsConfirmed = true
        sessions.insert(session, at: 0)
        selectedID = session.id
        scheduleSave(session, immediately: true)
        composerFocusToken += 1
    }

    func select(_ id: UUID) { selectedID = id }

    func delete(_ session: Session) {
        tasks[session.id]?.cancel()
        sessions.removeAll { $0.id == session.id }
        sessionStore.delete(session.id)
        if selectedID == session.id { selectedID = sessions.first?.id }
    }

    /// Starts a conversation, or uses the current one, with `text` in the composer: the "Ask AI"
    /// buttons elsewhere in the window.
    func ask(_ text: String) {
        if current == nil || current?.profileID != proxy.activeProfileID { newThread() }
        draftInstruction(text)
    }

    func draftInstruction(_ text: String) {
        composerText = text
        composerFocusToken += 1
    }

    /// `executionMode` overrides the composer's mode for this one instruction.
    func send(_ raw: String? = nil, executionMode override: ExecutionMode? = nil, forceAI: Bool = false) {
        let prompt = (raw ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        if prompt == "/undo" || prompt == "/redo" {
            composerText = ""
            prompt == "/undo" ? undo() : redo()
            return
        }
        if current == nil { newThread() }
        guard var session = current, let live = liveText, let draft = document(for: live) else { return }
        if raw == nil { composerText = "" }
        // Each instruction works on the profile as it runs now.
        session.draftText = live
        if session.turns.isEmpty { session.title = String(prompt.prefix(40)) }

        let useAI = forceAI ? aiConfigured : effectiveUseAI
        let mode: Turn.Mode = useAI ? .ai(model: settings.modelLabel) : .local
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        var turn = Turn(prompt: prompt, mode: mode, steps: steps)
        turn.executionMode = override ?? executionMode
        var request = EditorEngine.Request(prompt: prompt, draft: draft, regions: session.regions(for: draft.targets), useAI: useAI,
                                           settings: settings, apiKey: apiKey, history: history(for: session, context: draft),
                                           shareRuleLiterals: shareRuleLiterals)
        request.search = useAI ? searchConfig : nil
        request.mode = turn.executionMode ?? .manual
        // Changes to the running core only make sense for the profile it runs.
        request.runtime = session.profileID == proxy.activeProfileID
        request.replyLanguage = Self.replyLanguage
        let proxy = proxy
        request.liveConnections = { domains in await proxy.connectionSummary(for: domains) }
        if useAI { turn.sentPayload = EditorEngine.payload(for: request) }
        session.turns.append(turn)
        session.updatedAt = .now
        current = session
        moveToTop(session.id)

        let engine = engine, finalRequest = request
        startTurn(sessionID: session.id, turnID: turn.id, draftText: live) { progress in
            try await engine.run(finalRequest, progress: progress)
        }
    }

    /// An edit of an existing group's members, as a proposal: the same apply, Mihomo check and
    /// review card as any other change.
    func editGroupMembers(_ name: String, members: [String]) {
        guard var session = current, let live = liveText, let draft = document(for: live), !isRunning,
              let group = draft.target(named: name), group.kind == .group else { return }
        let ids = members.compactMap { draft.target(named: $0)?.id }
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        let turn = Turn(prompt: String(localized: "修改策略组“\(name)”的成员"), mode: .local, steps: steps)
        session.draftText = live
        session.turns.append(turn)
        session.updatedAt = .now
        current = session
        let engine = engine, plan = EditPlan(operations: [.groupMembers(targetId: group.id, members: ids)]), regions = session.regions(for: draft.targets)
        startTurn(sessionID: session.id, turnID: turn.id, draftText: live) { progress in
            try await engine.run(plan: plan, draft: draft, regions: regions, progress: progress)
        }
    }

    private func moveToTop(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), index > 0 else { return }
        sessions.insert(sessions.remove(at: index), at: 0)
    }

    private func startTurn(sessionID: UUID, turnID: UUID, draftText: String,
                           work: @escaping @Sendable (@escaping @Sendable (EditorEngine.Progress) async -> Void) async throws -> EditorEngine.Output) {
        let started = Date()
        tasks[sessionID] = Task { [weak self] in
            do {
                let output = try await work { event in
                    await MainActor.run { self?.apply(event, sessionID: sessionID, turnID: turnID) }
                }
                self?.finish(sessionID: sessionID, turnID: turnID, started: started, draftText: draftText, output: output)
            } catch {
                self?.fail(sessionID: sessionID, turnID: turnID, started: started, error: error)
            }
        }
    }

    /// Earlier exchanges in anonymized form, so follow-ups like "那走香港" resolve.
    private func history(for session: Session, context draft: ConfigDocument) -> [(role: String, content: String)] {
        let anon = AnonymousContext(targets: draft.targets, regions: session.regions(for: draft.targets))
        var messages: [(String, String)] = []
        for turn in session.turns.suffix(6) where !turn.isNote {
            let reply: String
            switch turn.outcome {
            case .proposal(let proposal):
                let summary = proposal.items.filter { proposal.accepted.contains($0.id) }.map { item -> String in
                    if let group = item.group { return "新建策略组“\(group.name)”（\(group.regionCounts.keys.sorted().joined(separator: "、"))）" }  // for the AI
                    let target = item.targetID.flatMap(anon.label(forTargetID:)) ?? item.targetName ?? "删除"  // for the AI
                    return "\(item.subject) → \([.removeRule, .removeProvider].contains(item.kind) ? "删除" : target)"  // for the AI
                }.joined(separator: "；")
                reply = "\(proposal.status == .written ? "已应用" : "已提出修改")：\(summary)"  // for the AI
            case .clarification(let question, _), .clarify(let question, _): reply = question
            case .outOfScope(let text), .noChange(let text): reply = text
            case .runtime(let run):
                reply = "已执行：" + run.items.map { "\($0.step.summary)（\($0.state == .done ? "完成" : "失败")）" }.joined(separator: "；")  // for the AI
                    + (run.undone ? "；用户随后撤销了" : "")  // for the AI
            default: continue
            }
            messages.append(("user", anon.anonymize(turn.prompt)))
            messages.append(("assistant", reply))
        }
        return messages
    }

    private func apply(_ event: EditorEngine.Progress, sessionID: UUID, turnID: UUID) {
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            switch event {
            case .started(let index):
                turn.steps[index].state = .running
            case .finished(let index, let detail):
                turn.steps[index].state = .done
                turn.steps[index].detail = detail
            case .understanding(let text):
                turn.understanding = text
            case .reasoning(let text):
                turn.reasoning = text
            case .retrying(let problem):
                turn.repairedFrom = problem
                turn.steps[0].detail = String(localized: "第一次回答无法使用，已自动让 AI 修正")
            case .searching(let queries):
                let list = queries.formatted(.list(type: .and))
                turn.steps[0].detail = String(localized: "正在联网搜索：\(list)")
            case .searched(let records):
                turn.searches = (turn.searches ?? []) + records
                turn.steps[0].detail = String(localized: "已联网搜索 \(turn.searches?.count ?? 0) 条，正在根据结果生成计划")
            case .checking(let domains):
                turn.steps[0].detail = String(localized: "正在本机检查 \(domains.count) 个域名命中哪条规则")
            case let .checked(records, sent):
                turn.checks = (turn.checks ?? []) + records
                if var payload = turn.sentPayload {
                    payload.checks = (payload.checks ?? []) + [sent]
                    turn.sentPayload = payload
                }
                turn.steps[0].detail = String(localized: "已检查 \(turn.checks?.count ?? 0) 个域名，正在根据结果生成计划")
            case .lookedUp(let hints):
                turn.lookups = hints
                if turn.sentPayload != nil { turn.sentPayload?.lookups = hints.message }
            }
        }
    }

    private func finish(sessionID: UUID, turnID: UUID, started: Date, draftText: String, output: EditorEngine.Output) {
        tasks[sessionID] = nil
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            turn.duration = Date().timeIntervalSince(started)
            for index in turn.steps.indices where turn.steps[index].state == .waiting { turn.steps.removeSubrange(index...); break }
            switch output {
            case let .proposal(plan, items, candidate, validation):
                turn.outcome = .proposal(.init(plan: plan, items: items, accepted: Set(items.map(\.id)), baseDraft: draftText,
                                               candidate: candidate, validation: validation, status: .pending))
            case .noChange(let text): turn.outcome = .noChange(text)
            case let .clarification(question, options): turn.outcome = .clarify(question, options: options)
            case .outOfScope(let text): turn.outcome = .outOfScope(text)
            case .runtime(let steps): turn.outcome = .runtime(RuntimeRun(steps: steps))
            }
        }
        if case .proposal = output { autoWriteIfAllowed(sessionID: sessionID, turnID: turnID) }
        if case .runtime = output { perform(sessionID: sessionID, turnID: turnID) }
        announce(String(localized: "处理完成"))
    }

    private func fail(sessionID: UUID, turnID: UUID, started: Date, error: Error) {
        tasks[sessionID] = nil
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            turn.duration = Date().timeIntervalSince(started)
            let cancelled = error is CancellationError || (error as? AIFailure) == .cancelled
            for index in turn.steps.indices where [.running, .waiting].contains(turn.steps[index].state) {
                turn.steps[index].state = cancelled ? .cancelled : (turn.steps[index].state == .running ? .failed : .cancelled)
            }
            if cancelled { turn.outcome = .cancelled; return }
            let failure = error as? AIFailure
            turn.outcome = .failure(message: message(for: error), opensSettings: failure?.opensSettings ?? false, canUseLocal: turn.mode != .local)
        }
    }

    func cancel() {
        guard let id = current?.id else { return }
        tasks[id]?.cancel()
    }

    private func mutateTurn(sessionID: UUID, turnID: UUID, _ change: (inout Turn) -> Void) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let turnIndex = sessions[sessionIndex].turns.firstIndex(where: { $0.id == turnID }) else { return }
        change(&sessions[sessionIndex].turns[turnIndex])
        sessions[sessionIndex].updatedAt = .now
        scheduleSave(sessions[sessionIndex])
    }

    // MARK: Reviewing and applying

    func setAccepted(_ accepted: Bool, item: Int, turnID: UUID) {
        guard let turn = current?.turns.first(where: { $0.id == turnID }), var proposal = turn.proposal, proposal.status == .pending else { return }
        if accepted { proposal.accepted.insert(item) } else { proposal.accepted.remove(item) }
        rebuild(turnID: turnID, plan: proposal.plan, accepted: proposal.accepted)
    }

    /// Replaces a pending new group's name, type and members, then rebuilds and re-validates.
    func editNewGroup(_ target: GroupEditTarget, name: String, type: String, members: [String]) {
        guard let draft, let turn = current?.turns.first(where: { $0.id == target.turnID }), let proposal = turn.proposal,
              proposal.status == .pending, target.itemID < proposal.plan.operations.count,
              case .group(let old) = proposal.plan.operations[target.itemID] else { return }
        let ids = members.compactMap { name in draft.target(named: name)?.id }
        var plan = proposal.plan
        plan.operations[target.itemID] = .group(EditPlan.NewGroup(id: old.id, name: name.trimmingCharacters(in: .whitespaces), type: type, regions: [], members: ids))
        rebuild(turnID: target.turnID, plan: plan, accepted: proposal.accepted)
    }

    /// Applies `plan` with `accepted` to the turn's base in the background; applying waits.
    private func rebuild(turnID: UUID, plan: EditPlan, accepted: Set<Int>) {
        guard let session = current, let turn = session.turns.first(where: { $0.id == turnID }), let proposal = turn.proposal,
              let base = document(for: proposal.baseDraft) else { return }
        mutateTurn(sessionID: session.id, turnID: turnID) { turn in
            turn.proposal?.accepted = accepted
            turn.proposal?.plan = plan
        }
        let engine = engine, items = proposal.items, sessionID = session.id, regions = session.regions(for: base.targets)
        let isLatest: @Sendable (Turn) -> Bool = { $0.proposal?.accepted == accepted && $0.proposal?.plan == plan }
        revalidating.insert(turnID)
        Task { [weak self] in
            defer { if let turn = self?.current?.turns.first(where: { $0.id == turnID }), isLatest(turn) { self?.revalidating.remove(turnID) } }
            do {
                let result = try await engine.reapply(plan: plan, accepted: accepted, draft: base, regions: regions, previous: items)
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    guard isLatest(turn) else { return }
                    turn.proposal?.candidate = result.candidate
                    turn.proposal?.items = result.items
                    turn.proposal?.validation = result.validation
                }
            } catch {
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    guard isLatest(turn) else { return }
                    turn.proposal?.validation = ValidationResult(status: .failed, message: self?.message(for: error) ?? "")
                }
            }
        }
    }

    /// A proposal applies only onto the text it was made from: anything else changed since
    /// (another change, a subscription update) makes it stale.
    func canWrite(_ turn: Turn) -> Bool {
        guard let proposal = turn.proposal, proposal.status == .pending, let live = liveText else { return false }
        return !proposal.accepted.isEmpty && proposal.validation.status != .failed && proposal.baseDraft == live
            && !isRunning && !revalidating.contains(turn.id)
    }

    /// Records the proposal in "my routing"; the running core takes it at once.
    func write(turnID: UUID? = nil) {
        guard var session = current, let profileID = session.profileID, let id = turnID ?? latestProposalTurnID,
              let index = session.turns.firstIndex(where: { $0.id == id }),
              var proposal = session.turns[index].proposal, canWrite(session.turns[index]) else { return }
        let edit = RoutingLayer.Edit(id: id, source: .agent, prompt: session.turns[index].prompt, plan: proposal.plan,
                                     accepted: proposal.accepted, items: proposal.items, base: proposal.baseDraft)
        guard proxy.addEdit(edit, to: profileID) else { return }
        proposal.writtenFrom = proposal.baseDraft
        proposal.writtenTo = proposal.candidate
        proposal.status = .written
        session.turns[index].proposal = proposal
        session.draftText = proposal.candidate
        session.updatedAt = .now
        current = session
        showToast(applyMessage(count: proposal.accepted.count), undoable: true)
        announce(String(localized: "已应用"))
    }

    private func applyMessage(count: Int) -> String {
        proxy.isRunning && !profileIsInactive
            ? String(localized: "已应用 \(count) 项修改，内核已生效")
            : String(localized: "已应用 \(count) 项修改，下次启动内核时生效")
    }

    /// Applies a fresh proposal when its turn's execution mode allows it (see `ExecutionMode`).
    private func autoWriteIfAllowed(sessionID: UUID, turnID: UUID) {
        guard current?.id == sessionID, let turn = current?.turns.first(where: { $0.id == turnID }),
              let mode = turn.executionMode, let proposal = turn.proposal,
              mode.writesAutomatically(items: proposal.items.filter { proposal.accepted.contains($0.id) }, validation: proposal.validation,
                                       instruction: turn.prompt),
              canWrite(turn) else { return }
        write(turnID: turnID)
        mutateTurn(sessionID: sessionID, turnID: turnID) { $0.autoWritten = true }
    }

    func discard(turnID: UUID) {
        guard let session = current else { return }
        mutateTurn(sessionID: session.id, turnID: turnID) { turn in
            if turn.proposal?.status == .pending { turn.proposal?.status = .discarded }
        }
    }

    // MARK: Runtime actions

    private func runtimeRun(_ sessionID: UUID, _ turnID: UUID) -> RuntimeRun? {
        guard let turn = sessions.first(where: { $0.id == sessionID })?.turns.first(where: { $0.id == turnID }),
              case .runtime(let run) = turn.outcome else { return nil }
        return run
    }

    private func updateRun(_ sessionID: UUID, _ turnID: UUID, _ change: (inout RuntimeRun) -> Void) {
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            guard case .runtime(var run) = turn.outcome else { return }
            change(&run)
            turn.outcome = .runtime(run)
        }
    }

    /// Runs the turn's actions in order on the running core, recording what each replaced.
    private func perform(sessionID: UUID, turnID: UUID) {
        guard let run = runtimeRun(sessionID, turnID) else { return }
        Task { [weak self] in
            for item in run.items {
                self?.updateRun(sessionID, turnID) { $0.items[item.id].state = .running }
                do {
                    guard let self else { return }
                    let (result, undo) = try await self.perform(item.step)
                    self.updateRun(sessionID, turnID) { run in
                        run.items[item.id].state = .done
                        run.items[item.id].result = result
                        run.items[item.id].undo = undo
                    }
                } catch {
                    self?.updateRun(sessionID, turnID) { run in
                        run.items[item.id].state = .failed
                        run.items[item.id].result = self?.message(for: error)
                    }
                }
            }
            if let run = self?.runtimeRun(sessionID, turnID), run.canUndo {
                self?.showToast(String(localized: "已执行，可以撤销"), undoable: true)
            }
        }
    }

    private func perform(_ step: RuntimeStep) async throws -> (String, RuntimeRun.Undo?) {
        switch step {
        case let .select(group, node):
            let previous = try await proxy.choose(node, in: group)
            return (String(localized: "“\(group)”已切换到 \(node)"), previous.map { .select(group: group, node: $0) })
        case let .selectFastest(group, regions):
            let delays = try await proxy.testNow(group)
            // Real nodes only: DIRECT and nested groups would always look fastest.
            let members = try await proxy.liveGroup(group).members
                .filter { !$0.isGroup && !ConfigDocument.builtinPolicies.contains($0.name) }.map(\.name)
            let candidates = members.filter { name in
                guard let delay = delays[name], delay > 0 else { return false }
                return regions.isEmpty || regions.contains(Region.infer(from: name))
            }
            guard let best = candidates.min(by: { delays[$0]! < delays[$1]! }) else {
                throw EditorError(regions.isEmpty ? String(localized: "“\(group)”里的节点都测速超时了。")
                                                  : String(localized: "“\(group)”里没有可用的所选地区节点。"))
            }
            let previous = try await proxy.choose(best, in: group)
            return (String(localized: "“\(group)”已切换到 \(best)（\(String(delays[best]!)) ms）"), previous.map { .select(group: group, node: $0) })
        case let .mode(raw):
            guard let mode = ProxyStore.Mode(rawValue: raw) else { throw EditorError(String(localized: "不支持的模式。")) }
            let previous = try await proxy.switchMode(mode)
            return (String(localized: "已切换到\(mode.title)模式"), previous == mode ? nil : .mode(previous.rawValue))
        case let .test(group):
            let delays = try await proxy.testNow(group)
            let working = delays.filter { $0.value > 0 }
            guard let best = working.min(by: { $0.value < $1.value }) else {
                return (String(localized: "“\(group)”测速完成，没有可用的节点"), nil)
            }
            return (String(localized: "“\(group)”测速完成：\(working.count) 个可用，最快 \(best.key)（\(String(best.value)) ms）"), nil)
        case let .closeConnections(host):
            let count = try await proxy.closeConnections(host: host)
            return (String(localized: "已断开 \(count) 个到 \(host) 的连接"), nil)
        }
    }

    /// Puts back the nodes and mode a turn's actions replaced, last first.
    private func undoRuntime(sessionID: UUID, turnID: UUID) {
        guard let run = runtimeRun(sessionID, turnID), run.canUndo else { return }
        updateRun(sessionID, turnID) { $0.undone = true }
        Task { [weak self] in
            do {
                for item in run.items.reversed() {
                    switch item.undo {
                    case let .select(group, node)?: try await self?.proxy.choose(node, in: group)
                    case let .mode(raw)?: if let mode = ProxyStore.Mode(rawValue: raw) { try await self?.proxy.switchMode(mode) }
                    case nil: break
                    }
                }
                self?.showToast(String(localized: "已撤销"))
            } catch {
                self?.updateRun(sessionID, turnID) { $0.undone = false }
                self?.showToast(self?.message(for: error) ?? "")
            }
        }
    }

    /// The last applied change of this conversation, turned off in "my routing"; or, when the
    /// latest thing done was a runtime action, that action put back.
    func undo() {
        guard var session = current, let profileID = session.profileID, !isRunning else { return }
        let lastRuntime = session.turns.lastIndex { if case .runtime(let run) = $0.outcome { run.canUndo } else { false } }
        let lastWrite = session.turns.lastIndex { $0.proposal?.status == .written }
        if let lastRuntime, lastRuntime > (lastWrite ?? -1) {
            undoRuntime(sessionID: session.id, turnID: session.turns[lastRuntime].id)
            return
        }
        guard let index = lastWrite else { return }
        proxy.setEdit(session.turns[index].id, enabled: false, in: profileID)
        session.turns[index].proposal?.status = .undone
        session.turns.append(Turn(prompt: "", mode: .local, steps: [], outcome: .note(String(localized: "已撤销这项修改，分流恢复到之前的状态。"))))
        session.draftText = (try? proxy.effectiveText(of: profileID)) ?? session.draftText
        current = session
        showToast(String(localized: "已撤销"))
    }

    /// Turns the most recently undone change back on.
    func redo() {
        guard var session = current, let profileID = session.profileID, !isRunning,
              let index = session.turns.lastIndex(where: { $0.proposal?.status == .undone }) else { return }
        proxy.setEdit(session.turns[index].id, enabled: true, in: profileID)
        session.turns[index].proposal?.status = .written
        session.turns.append(Turn(prompt: "", mode: .local, steps: [], outcome: .note(String(localized: "已重新应用这项修改。"))))
        session.draftText = (try? proxy.effectiveText(of: profileID)) ?? session.draftText
        current = session
        showToast(String(localized: "已重做"))
    }

    var canUndo: Bool {
        guard let turns = current?.turns, !isRunning else { return false }
        return turns.contains { turn in
            if case .runtime(let run) = turn.outcome { return run.canUndo }
            return turn.proposal?.status == .written
        }
    }

    /// Undoes one runtime turn from its own card.
    func undoRuntime(turnID: UUID) {
        guard let id = current?.id else { return }
        undoRuntime(sessionID: id, turnID: turnID)
    }
    var canRedo: Bool { current?.turns.contains { $0.proposal?.status == .undone } == true && !isRunning }

    func retry(turnID: UUID, useLocal: Bool = false) {
        guard let turn = current?.turns.first(where: { $0.id == turnID }) else { return }
        if useLocal { useAI = false }
        send(turn.prompt)
    }

    /// Veer has no inspector; changes show in the turn itself.
    func inspectorShowsChanges(of turnID: UUID) -> Bool { false }
    func showDiff(for turnID: UUID) {}

    // MARK: Settings & key

    func saveKey(_ key: String, remember: Bool) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if remember {
            try keyStore.save(trimmed, for: settings.provider.rawValue)
            keySaved = true
            sessionKey = nil
        } else {
            sessionKey = trimmed
        }
    }

    func forgetKey() {
        keyStore.delete(for: settings.provider.rawValue)
        keySaved = false
        sessionKey = nil
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "aiSettings") }
    }

    /// What the next AI request may use for search; nil when search is off.
    var searchConfig: SearchConfig? {
        guard searchSettings.enabled else { return nil }
        let provider = searchSettings.provider
        let key: String?
        if let service = provider.aiServiceKey {
            key = sessionKeys[service] ?? keyStore.read(for: service.rawValue)
        } else {
            key = provider.needsKey ? keyStore.read(for: provider.keyAccount) : nil
        }
        return SearchConfig(provider: provider, apiKey: key, baseURL: provider.needsURL ? searchSettings.searxngURL : nil)
    }

    /// Switches service, keeping the address and model the user had for it last time.
    func selectProvider(_ provider: AIProvider) {
        guard provider != settings.provider else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "aiSettings.\(settings.provider.rawValue)") }
        if let data = defaults.data(forKey: "aiSettings.\(provider.rawValue)"), let saved = try? JSONDecoder().decode(AISettings.self, from: data),
           saved.provider == provider {
            settings = saved
        } else {
            settings = AISettings(provider: provider)
        }
    }

    func fetchModels() async throws -> Int {
        let current = settings
        let models = try await AIClient().listModels(settings: current, apiKey: apiKey)
        guard settings.provider == current.provider else { return 0 }
        settings.fetchedModels = models
        return models.count
    }

    func deleteAllSessions() {
        for session in sessions { delete(session) }
    }

    // MARK: Persistence & feedback

    private func scheduleSave(_ session: Session, immediately: Bool = false) {
        saveWork[session.id]?.cancel()
        let store = sessionStore, queue = saveQueue
        let work = DispatchWorkItem { queue.async { try? store.save(session) } }
        saveWork[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.4), execute: work)
    }

    func flush() {
        for work in saveWork.values { work.cancel() }
        let store = sessionStore, snapshot = sessions
        saveQueue.sync { for session in snapshot { try? store.save(session) } }
    }

    func showToast(_ message: String, undoable: Bool = false) {
        toastWork?.cancel()
        toast = Toast(message: message, undoable: undoable)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func message(for error: Error) -> String {
        if let editor = error as? EditorError { return editor.message }
        if let failure = error as? AIFailure { return failure.message }
        return String(localized: "发生未知错误，请重试。")
    }
}
