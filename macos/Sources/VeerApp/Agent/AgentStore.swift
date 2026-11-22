import Observation
import SwiftUI
import VeerCore
import VeerProxy
#if os(macOS)
import AppKit
#else
// The iOS prototype compiles this file as is (ios/VeerMobile.xcodeproj); only `announce` differs.
import UIKit
#endif

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
    var warning = false
    var recordedIn: UUID?
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
    /// An undo or redo from the moment it is asked for until the core has it (`ReversalState`).
    var reversal: ReversalState = .idle
    var reversingTurnID: UUID?
    @ObservationIgnored private let reversalWork = SerialWork()
    private var pendingReversals = 0
    @ObservationIgnored var reversalReset: Task<Void, Never>?
    /// Where the conversation on screen is scrolled to, kept by `ConversationView` as it scrolls, and
    /// the copy a move between the panel and the window hands to the view that comes next. Not
    /// observed: nothing is drawn from them.
    @ObservationIgnored var scrollSpot: ScrollSpot?
    @ObservationIgnored var scrollHandoff: ScrollSpot?
    /// Edit → Undo and Redo. `MainView` gives it the window's undo manager.
    @ObservationIgnored let changes = ReversibleChanges()
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
    /// Used for settings operations as well as the conversation engine's injected transport.
    /// The default preserves the Mac behaviour; offline demonstrations can replace it.
    let modelClient: AIClient
    @ObservationIgnored let defaults: UserDefaults
    private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var documentCache: [(text: String, document: ConfigDocument)] = []
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "veer.thread-save", qos: .utility)
    @ObservationIgnored private var saveWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    /// Files and images waiting in the composer.
    var pendingAttachments: [ChatAttachment] = []
    /// How many are still being read.
    var loadingAttachments = 0
    /// Why the last ones couldn't be added or sent, shown in the composer.
    var attachmentProblem: String?
    /// Set by the menu command; the composer shows the open panel.
    var choosingAttachments = false
    /// What each turn sent, for trying it again. Only for this launch: their contents aren't saved.
    @ObservationIgnored private var sentAttachments: [UUID: [ChatAttachment]] = [:]

    init(proxy: ProxyStore, keyStore: KeyStoring? = nil, engine: EditorEngine? = nil, defaults: UserDefaults = .standard, persist: Bool = true,
         modelClient: AIClient = AIClient()) {
        self.proxy = proxy
        sessionStore = SessionStore(directory: proxy.paths.threads)
        self.keyStore = keyStore ?? proxy.profileStore.secrets
        let geo = GeoDataStore.shared
        // The Agent's domain checks read the same rule-set files and geodata as Route Test, so the two agree.
        let home = proxy.paths.core
        let checker = DomainChecker(geo: geo, source: { draft in await RouteTestSource.load(config: draft.text, home: home, fallback: geo).data })
        self.engine = engine ?? EditorEngine(searcher: WebSearchService(geo: geo), lookup: InstructionLookup(geo: geo), checker: checker)
        self.defaults = defaults
        self.modelClient = modelClient
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
        proxy.editsRemoved = { [weak self] ids in self?.editsWereRemoved(ids) }
        proxy.profilesMerged = { [weak self] moved in self?.profilesWereMerged(moved) }
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

    /// A conversation whose profile was deleted: kept to read, closed to new instructions and changes,
    /// which would have no profile to go to.
    func isArchived(_ session: Session) -> Bool {
        session.profileID.map { id in !proxy.profiles.contains { $0.id == id } } ?? true
    }

    var isArchived: Bool { current.map(isArchived) ?? false }

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
        changes.forget(group: session.id)
        tasks[session.id]?.cancel()
        sessions.removeAll { $0.id == session.id }
        sessionStore.delete(session.id)
        if selectedID == session.id { selectedID = sessions.first?.id }
    }

    /// Starts a conversation, or uses the current one, with `text` in the composer: the "Ask Agent"
    /// buttons elsewhere in the window.
    func ask(_ text: String) {
        if current == nil || current?.profileID != proxy.activeProfileID { newThread() }
        draftInstruction(text)
    }

    /// Shows the Agent without leaving the page: its window, the panel beside the page, or the Agent
    /// page when that is the page. `fresh` starts a new conversation; `text` goes into the composer.
    func open(asking text: String? = nil, fresh: Bool = false) {
        showAgent()
        if fresh { newThread() }
        if let text { ask(text) } else { composerFocusToken += 1 }
    }

    // MARK: Attachments

    /// Reads them off the main thread. Those that can't be read say why together, and leave the rest.
    func attach(_ urls: [URL]) {
        guard canAttach else { return }
        attachmentProblem = nil
        loadingAttachments += urls.count
        Task { [weak self] in
            var problems: [String] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let result = await Task.detached { Result { try AttachmentReader.read(url) } }.value
                self?.loadingAttachments -= 1
                if let problem = self?.add(result) { problems.append(problem) }
            }
            self?.report(problems)
        }
    }

    /// A pasted image, which has no file name of its own.
    func attach(imageData data: Data) {
        guard canAttach else { return }
        attachmentProblem = nil
        loadingAttachments += 1
        let name = String(localized: "粘贴的图片")
        Task { [weak self] in
            let result = await Task.detached { Result { try AttachmentReader.image(from: data, name: name) } }.value
            self?.loadingAttachments -= 1
            if let problem = self?.add(result) { self?.report([problem]) }
        }
    }

    private var canAttach: Bool {
        if effectiveUseAI { return true }
        report([String(localized: "图片和文件只在 AI 解析时可用")])
        return false
    }

    private func canSend(_ attachments: [ChatAttachment], forceAI: Bool) -> Bool {
        guard !attachments.isEmpty else { return true }
        guard forceAI ? aiConfigured : effectiveUseAI else {
            report([String(localized: "本地解析读不了图片和文件，请先选择 AI。")])
            return false
        }
        guard settings.provider.acceptsImages || attachments.allSatisfy({ $0.image == nil }) else {
            report([String(localized: "\(settings.provider.title) 不能读取图片，请换一个 AI 服务，或移除图片。")])
            return false
        }
        return true
    }

    private func record(_ attachments: [ChatAttachment], on turn: inout Turn) {
        guard !attachments.isEmpty else { return }
        turn.attachments = attachments.map(\.info)
        sentAttachments[turn.id] = attachments
        // What a file or image says isn't what the user says: it never applies without a look.
        if turn.executionMode != .plan { turn.executionMode = .manual }
    }

    /// What went wrong, if it couldn't be added.
    private func add(_ result: Result<ChatAttachment, Error>) -> String? {
        switch result {
        case .failure(let error): return message(for: error)
        case .success(let attachment):
            guard pendingAttachments.count < ChatAttachment.maxCount else {
                return String(localized: "一次最多发送 \(ChatAttachment.maxCount) 个图片或文件。")
            }
            pendingAttachments.append(attachment)
            return nil
        }
    }

    /// In the composer, where they stay until the next try: a toast would leave before several were
    /// read, and says everything with a check mark.
    private func report(_ problems: [String]) {
        let unique = problems.uniqued()
        guard !unique.isEmpty else { return }
        attachmentProblem = unique.joined(separator: "\n")
        announce(unique.joined(separator: " "))
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        attachmentProblem = nil
    }

    func draftInstruction(_ text: String) {
        composerText = text
        composerFocusToken += 1
    }

    /// `executionMode` overrides the composer's mode for this one instruction.
    /// `attachments` go with a `raw` instruction, which otherwise leaves what waits in the composer alone.
    func send(_ raw: String? = nil, attachments sent: [ChatAttachment] = [], executionMode override: ExecutionMode? = nil, forceAI: Bool = false) {
        guard raw != nil || loadingAttachments == 0 else { return }
        let attachments = raw == nil ? pendingAttachments : sent
        var prompt = (raw ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty, !attachments.isEmpty { prompt = String(localized: "请看附件。") }
        guard !prompt.isEmpty, !isRunning, !isArchived, canSend(attachments, forceAI: forceAI) else { return }
        if prompt == "/undo" || prompt == "/redo" {
            composerText = ""
            prompt == "/undo" ? undo() : redo()
            return
        }
        if current == nil { newThread() }
        guard var session = current, let live = liveText, let draft = document(for: live) else { return }
        if raw == nil {
            composerText = ""
            pendingAttachments = []
        }
        attachmentProblem = nil
        // Each instruction works on the profile as it runs now.
        session.draftText = live
        if session.turns.isEmpty { session.title = String(prompt.prefix(40)) }

        let useAI = forceAI ? aiConfigured : effectiveUseAI
        let mode: Turn.Mode = useAI ? .ai(model: settings.modelLabel) : .local
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        var turn = Turn(prompt: prompt, mode: mode, steps: steps)
        turn.executionMode = override ?? executionMode
        record(attachments, on: &turn)
        var request = EditorEngine.Request(prompt: prompt, draft: draft, regions: session.regions(for: draft.targets), useAI: useAI,
                                           settings: settings, apiKey: apiKey, history: history(for: session, context: draft),
                                           shareRuleLiterals: shareRuleLiterals)
        request.search = useAI ? searchConfig : nil
        request.mode = turn.executionMode ?? .manual
        // Changes to the running core only make sense for the profile it runs.
        request.runtime = session.profileID == proxy.activeProfileID
        request.replyLanguage = Self.replyLanguage
        request.attachments = attachments
        let proxy = proxy
        request.liveConnections = { domains in await proxy.connectionSummary(for: domains) }
        if let profileID = session.profileID { request.appLookup = { query in await proxy.appLookup(query, profile: profileID) } }
        if useAI { turn.sentPayload = EditorEngine.payload(for: request) }
        session.turns.append(turn)
        session.updatedAt = .now
        current = session
        moveToTop(session.id)

        let engine = engine, finalRequest = request
        startTurn(session: session, turnID: turn.id) { progress in
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
        startTurn(session: session, turnID: turn.id) { progress in
            try await engine.run(plan: plan, draft: draft, regions: regions, progress: progress)
        }
    }

    private func moveToTop(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), index > 0 else { return }
        sessions.insert(sessions.remove(at: index), at: 0)
    }

    private func startTurn(session: Session, turnID: UUID,
                           work: @escaping @Sendable (@escaping @Sendable (EditorEngine.Progress) async -> Void) async throws -> EditorEngine.Output) {
        let sessionID = session.id
        let started = Date()
        tasks[sessionID] = Task { [weak self] in
            do {
                let output = try await work { event in
                    await MainActor.run { self?.apply(event, sessionID: sessionID, turnID: turnID) }
                }
                self?.finish(session: session, turnID: turnID, started: started, output: output)
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
            case .appRouting(let proposal):
                let summary = proposal.changes.map { "\($0.app.name) → \($0.remove ? "删除规则" : ($0.target?.promptName ?? "只改域名例外"))" }  // for the AI
                reply = (proposal.status == .applied ? "已应用应用分流：" : "已提出应用分流：") + anon.anonymize(summary.joined(separator: "；"))  // for the AI
            case .runtime(let run):
                reply = "已执行：" + run.items.map { "\($0.step.summary)（\($0.state == .done ? "完成" : "失败")）" }.joined(separator: "；")  // for the AI
                    + (run.undone ? "；用户随后撤销了" : "")  // for the AI
            default: continue
            }
            let attached = turn.attachments.map { list in "（附件：" + list.map(\.name).joined(separator: "、") + "）" } ?? ""  // for the AI
            messages.append(("user", anon.anonymize(turn.prompt) + attached))
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
            case .checking, .lookingUpApps, .lookingFurther:
                turn.steps[0].detail = Self.lookingUpDetail(event)
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

    private func finish(session: Session, turnID: UUID, started: Date, output: EditorEngine.Output) {
        let sessionID = session.id
        tasks[sessionID] = nil
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            turn.duration = Date().timeIntervalSince(started)
            for index in turn.steps.indices where turn.steps[index].state == .waiting { turn.steps.removeSubrange(index...); break }
            switch output {
            case let .proposal(plan, items, candidate, validation):
                turn.outcome = .proposal(.init(plan: plan, items: items, accepted: Set(items.map(\.id)), baseDraft: session.draftText,
                                               candidate: candidate, validation: validation, status: .pending))
            case .noChange(let text): turn.outcome = .noChange(text)
            case let .clarification(question, options): turn.outcome = .clarify(question, options: options)
            case .outOfScope(let text): turn.outcome = .outOfScope(text)
            case .runtime(let steps): turn.outcome = .runtime(RuntimeRun(steps: steps, profileID: session.profileID))
            case .appRouting(let changes):
                turn.outcome = .appRouting(AppRoutingProposal(changes: changes, profileID: sessions.first { $0.id == sessionID }?.profileID))
            }
        }
        if case .appRouting = output { checkAppRouting(sessionID: sessionID, turnID: turnID) }
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

    /// What a turn's first step says while Veer looks something up for the model.
    static func lookingUpDetail(_ event: EditorEngine.Progress) -> String? {
        switch event {
        case .checking(let domains): String(localized: "正在本机检查 \(domains.count) 个域名命中哪条规则")
        case .lookingFurther: String(localized: "AI 想让你提供可以查到的信息，已让它先自己查")
        case .lookingUpApps(let query?): String(localized: "正在查询本机应用：\(query)")
        case .lookingUpApps(nil): String(localized: "正在查询本机应用和应用规则")
        default: nil
        }
    }

    func mutateTurn(sessionID: UUID, turnID: UUID, _ change: (inout Turn) -> Void) {
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
        let group = directGroup(for: proposal, turn: session.turns[index])
        proposal.previousDirectNode = group.flatMap { name in proxy.groups.first(where: { $0.name == name })?.now }
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
        recordApplied(turnID: id, in: session.id)
        if let group, proxy.isRunning, !profileIsInactive {
            Task { [weak self] in
                guard let self, await selectAfterEdit("DIRECT", in: group, session: session, turnID: id, status: .written) == false else { return }
                proxy.notice = selectionFailure(node: "DIRECT", group: group)
            }
        }
    }

    private func directGroup(for proposal: Turn.Proposal, turn: Turn) -> String? {
        guard let base = document(for: proposal.baseDraft) else { return nil }
        return DedicatedGroupRoute.groupToSwitch(after: turn.prompt, in: base, plan: proposal.plan,
                                                accepted: proposal.accepted, mode: turn.executionMode ?? .manual)
    }

    /// The core reloads after the edit, so it may not know its new members straight away.
    private func selectAfterEdit(_ node: String, in group: String, session: Session, turnID: UUID, status: Turn.ProposalStatus) async -> Bool? {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return nil }
            do {
                return try await proxy.coreConfigWork.run { [self] in
                    let turn = sessions.first { $0.id == session.id }?.turns.first { $0.id == turnID }
                    guard proxy.activeProfileID == session.profileID, proxy.switchingTo == nil, proxy.isRunning,
                          turn?.proposal?.status == status else { return nil }
                    try await proxy.choose(node, in: group)
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    private func selectionFailure(node: String, group: String) -> String {
        String(localized: "“\(group)”未能切换到 \(node)，请在代理页重试。")
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
              // A web page saying a domain works direct is not enough to send it there unreviewed.
              !ExecutionMode.needsReviewAfterSearch(items: proposal.items.filter { proposal.accepted.contains($0.id) },
                                                    searched: turn.searches?.isEmpty == false),
              canWrite(turn) else { return }
        write(turnID: turnID)
        mutateTurn(sessionID: sessionID, turnID: turnID) { $0.autoWritten = true }
    }

    func discard(turnID: UUID) {
        guard let session = current, !isArchived else { return }
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
                    let (result, undo) = try await self.perform(item.step, profileID: run.profileID)
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
            if let self, let run = runtimeRun(sessionID, turnID), run.canUndo, let profileID = run.profileID,
               proxy.profiles.contains(where: { $0.id == profileID }) {
                showToast(String(localized: "已执行，可以撤销"), undoable: true)
                // Once: there is no redo for a node or mode put back.
                changes.made(String(localized: "切换节点或模式"), id: turnID, group: sessionID, undoTo: false) { [weak self] _ in
                    if self?.selectedID != sessionID { self?.select(sessionID) }
                    self?.undoRuntime(sessionID: sessionID, turnID: turnID)
                    return false
                }
            }
        }
    }

    private func checkRuntimeProfile(_ profileID: UUID?) throws {
        guard let profileID, proxy.activeProfileID == profileID, proxy.switchingTo == nil else {
            throw EditorError(String(localized: "配置已经切换，没有执行这项操作。"))
        }
    }

    private func perform(_ step: RuntimeStep, profileID: UUID?) async throws -> (String, RuntimeRun.Undo?) {
        try checkRuntimeProfile(profileID)
        switch step {
        case let .select(group, node):
            let previous = try await selectRuntimeNode(node, in: group, profileID: profileID)
            return (String(localized: "“\(group)”已切换到 \(node)"), previous.map { .select(group: group, node: $0) })
        case let .selectFastest(group, regions):
            // Results from the last minute count; only older or missing ones are tested again.
            let delays = try await proxy.testNow(group, reuseFresh: true)
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
            let previous = try await selectRuntimeNode(best, in: group, profileID: profileID)
            return (String(localized: "“\(group)”已切换到 \(best)（\(String(delays[best]!)) ms）"), previous.map { .select(group: group, node: $0) })
        case let .mode(raw):
            guard let mode = ProxyStore.Mode(rawValue: raw) else { throw EditorError(String(localized: "不支持的模式。")) }
            let previous = try await proxy.coreConfigWork.run { [self] in
                try checkRuntimeProfile(profileID)
                return try await proxy.switchMode(mode)
            }
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

    private func selectRuntimeNode(_ node: String, in group: String, profileID: UUID?) async throws -> String? {
        try await proxy.coreConfigWork.run { [self] in
            try checkRuntimeProfile(profileID)
            return try await proxy.choose(node, in: group)
        }
    }

    /// Puts back the nodes and mode a turn's actions replaced, last first.
    private func undoRuntime(sessionID: UUID, turnID: UUID) {
        guard runtimeRun(sessionID, turnID)?.canUndo == true else { return }
        enqueueReversal(in: sessionID) { [weak self] in
            await self?.restoreRuntime(sessionID: sessionID, turnID: turnID)
        }
    }

    private func restoreRuntime(sessionID: UUID, turnID: UUID) async {
        guard let run = runtimeRun(sessionID, turnID), run.canUndo,
              let profileID = run.profileID ?? sessions.first(where: { $0.id == sessionID })?.profileID else { return }
        reversingTurnID = turnID
        guard proxy.profiles.contains(where: { $0.id == profileID }) else {
            finishReversal(Self.runtimeUndoMissingProfile, redo: false, sessionID: sessionID, warning: true)
            return
        }
        setReversal(.undoing)
        let ticket = proxy.generation
        do {
            // Share the profile reload queue so a selector or mode write cannot land in the next profile.
            try await proxy.coreConfigWork.run { [self] in
                for item in run.items.reversed() {
                    guard proxy.activeProfileID == profileID, proxy.switchingTo == nil, proxy.generation == ticket else {
                        throw EditorError(String(localized: "请先切回这项操作所属的配置，再从对话卡片撤销。"))
                    }
                    switch item.undo {
                    case let .select(group, node)?: try await proxy.choose(node, in: group)
                    case let .mode(raw)?: if let mode = ProxyStore.Mode(rawValue: raw) { try await proxy.switchMode(mode) }
                    case nil: break
                    }
                }
            }
            updateRun(sessionID, turnID) { $0.undone = true }
            finishReversal(String(localized: "已撤销"), redo: false, sessionID: sessionID)
        } catch {
            finishReversal(message(for: error), redo: false, sessionID: sessionID, warning: true)
        }
    }

    /// Emptied, with Edit → Undo to bring it back: history the core can't send again, and a quiet
    /// way back is less of an interruption than asking first.
    func clearLogs() {
        guard !proxy.logs.isEmpty else { return }
        var saved = proxy.logs
        proxy.clearLogs()
        recordClear(String(localized: "menu.clearLogs", defaultValue: "清空日志")) { [weak self] restored in
            guard let proxy = self?.proxy else { return false }
            if restored {
                proxy.restoreLogs(saved)
            } else {
                saved = proxy.logs
                proxy.clearLogs()
            }
            return true
        }
    }

    func clearRequests() {
        guard !proxy.requests.isEmpty else { return }
        var saved = proxy.requests
        proxy.clearRequests()
        recordClear(String(localized: "menu.clearRequests", defaultValue: "清空请求记录")) { [weak self] restored in
            guard let proxy = self?.proxy else { return false }
            if restored {
                proxy.restoreRequests(saved)
            } else {
                saved = proxy.requests
                proxy.clearRequests()
            }
            return true
        }
    }

    private func recordClear(_ name: String, change: @escaping @MainActor (Bool) -> Bool) {
        changes.made(name, id: UUID(), group: Self.historyGroup, undoTo: true, change: change)
        showToast(String(localized: "已清空，可以用“撤销”恢复。"))
        announce(String(localized: "已清空，可以用“撤销”恢复。"))
    }

    /// For what belongs to no conversation, so that deleting one leaves these alone.
    private static let historyGroup = UUID()

    /// The last applied change of this conversation, turned off in "my routing"; or, when the
    /// latest thing done was a runtime action, that action put back.
    func undo() {
        guard let session = current, !isArchived, !refusedWhileBusy, !isReversing else { return }
        let lastRuntime = session.turns.lastIndex { if case .runtime(let run) = $0.outcome { canUndoRuntime(run) } else { false } }
        let lastWrite = session.turns.lastIndex { $0.proposal?.status == .written }
        if let lastRuntime, lastRuntime > (lastWrite ?? -1) {
            undoRuntime(turnID: session.turns[lastRuntime].id)
            return
        }
        if let lastWrite { undoProposal(session.turns[lastWrite].id, in: session.id) }
    }

    /// A proposal card acts on its own turn, even if a later runtime action can also be undone.
    func undoProposal(turnID: UUID) {
        guard let session = current, !isArchived, !refusedWhileBusy, !isReversing else { return }
        undoProposal(turnID, in: session.id)
    }

    private func undoProposal(_ id: UUID, in sessionID: UUID) {
        // As the menu would, so that it moves on to Redo. Else something else is next there, and this
        // change's own item goes, as it would no longer do anything.
        if !changes.undoIfNext(id), setApplied(false, turnID: id, in: sessionID) { changes.forget(id) }
    }

    /// Turns the most recently undone change back on.
    func redo() {
        guard let session = current, !isArchived, !refusedWhileBusy, !isReversing,
              let index = session.turns.lastIndex(where: { $0.proposal?.status == .undone }) else { return }
        let id = session.turns[index].id
        guard !changes.redoIfNext(id), setApplied(true, turnID: id, in: session.id) else { return }
        changes.forget(id)
        recordApplied(turnID: id, in: session.id)
    }

    private var refusedWhileBusy: Bool {
        if isRunning { showToast(String(localized: "Agent 正在处理，完成后再试。")) }
        return isRunning
    }

    /// Gone from "my routing", so nothing can turn these on or off: no menu item or button offers to.
    private func editsWereRemoved(_ ids: [UUID]) {
        for id in ids { changes.forget(id) }
        forgetMissingRuntimeChanges()
        for index in sessions.indices {
            var changed = false
            for turn in sessions[index].turns.indices where ids.contains(sessions[index].turns[turn].id) {
                let status = sessions[index].turns[turn].proposal?.status
                guard status == .written || status == .undone else { continue }
                sessions[index].turns[turn].proposal?.status = .discarded
                changed = true
            }
            if changed { scheduleSave(sessions[index], immediately: true) }
        }
    }

    /// Conversations about a duplicate profile that a merge removed go on with the one it kept.
    private func profilesWereMerged(_ moved: [UUID: UUID]) {
        for index in sessions.indices {
            guard let from = sessions[index].profileID, let to = moved[from], to != from else { continue }
            for turn in sessions[index].turns.indices {
                guard case .runtime(var run) = sessions[index].turns[turn].outcome, run.profileID == nil else { continue }
                run.profileID = from
                sessions[index].turns[turn].outcome = .runtime(run)
            }
            sessions[index].profileID = to
            scheduleSave(sessions[index], immediately: true)
        }
        forgetMissingRuntimeChanges()
    }

    private func forgetMissingRuntimeChanges() {
        let profiles = Set(proxy.profiles.map(\.id))
        for session in sessions {
            for turn in session.turns {
                guard case .runtime(let run) = turn.outcome, run.canUndo,
                      let original = run.profileID ?? session.profileID, !profiles.contains(original) else { continue }
                changes.forget(turn.id)
            }
        }
    }

    private func recordApplied(turnID: UUID, in sessionID: UUID) {
        changes.made(String(localized: "分流修改"), id: turnID, group: sessionID, undoTo: false) { [weak self] applied in
            self?.setApplied(applied, turnID: turnID, in: sessionID) ?? false
        }
    }

    /// Accept the request synchronously so UndoManager can record its opposite immediately.
    /// The actual changes and their confirmations run in the same order as the menu requests.
    private func setApplied(_ applied: Bool, turnID: UUID, in sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }), !isArchived(session),
              let status = session.turns.first(where: { $0.id == turnID })?.proposal?.status,
              status == .written || status == .undone else { return false }
        if !isReversing, status != (applied ? .undone : .written) { return false }
        if selectedID != sessionID { select(sessionID) }
        if tasks[sessionID] != nil {
            showToast(applied ? String(localized: "Agent 正在处理，完成后会重做。") : String(localized: "Agent 正在处理，完成后会撤销。"))
        }
        enqueueReversal(in: sessionID) { [weak self] in
            await self?.applyReversal(applied, turnID: turnID, in: sessionID)
        }
        return true
    }

    private func enqueueReversal(in sessionID: UUID, _ work: @escaping @MainActor () async -> Void) {
        pendingReversals += 1
        reversalWork.add { [weak self] in
            guard let self else { return }
            defer { pendingReversals -= 1 }
            await tasks[sessionID]?.value
            await work()
        }
    }

    private func applyReversal(_ applied: Bool, turnID: UUID, in sessionID: UUID) async {
        guard var session = sessions.first(where: { $0.id == sessionID }), !isArchived(session), let profileID = session.profileID,
              let index = session.turns.firstIndex(where: { $0.id == turnID }),
              session.turns[index].proposal?.status == (applied ? .undone : .written) else { return }
        // Deleted from "my routing" since: there is nothing left to turn on or off.
        guard proxy.setEdit(turnID, enabled: applied, in: profileID) else {
            let reason: String
            if proxy.routingStore.load(profileID).edits.contains(where: { $0.id == turnID }) {
                changes.forget(turnID)
                reason = proxy.notice ?? String(localized: "发生未知错误，请重试。")
            } else {
                editsWereRemoved([turnID])
                reason = String(localized: "这项修改已经从“我的分流”里删除。")
            }
            finishReversal(reason, redo: applied, sessionID: sessionID, warning: true)
            return
        }
        let status: Turn.ProposalStatus = applied ? .written : .undone
        session.turns[index].proposal?.status = status
        session.draftText = (try? proxy.effectiveText(of: profileID)) ?? session.draftText
        current = session
        let proposal = session.turns[index].proposal
        let apply = profileID == proxy.activeProfileID ? proxy.layerApply : nil
        await reportReversal(redo: applied, sessionID: sessionID, turnID: turnID, apply: apply) {
            guard let proposal, let group = directGroup(for: proposal, turn: session.turns[index]),
                  let node = applied ? "DIRECT" : proposal.previousDirectNode else { return nil }
            let selected = await selectAfterEdit(node, in: group, session: session, turnID: turnID, status: status)
            return selected == true ? nil : selectionFailure(node: node, group: group)
        }
    }

    func recordReversal(_ message: String, in sessionID: UUID, warning: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var note = Turn(prompt: "", mode: .local, steps: [], outcome: .note(message))
        if warning { note.noteWarning = true }
        sessions[index].turns.append(note)
        scheduleSave(sessions[index])
    }

    var isReversing: Bool { pendingReversals > 0 || reversal.isWorking }

    var canUndo: Bool {
        guard let turns = current?.turns, !isRunning, !isArchived, !isReversing else { return false }
        return turns.contains { turn in
            if case .runtime(let run) = turn.outcome { return canUndoRuntime(run) }
            return turn.proposal?.status == .written
        }
    }

    static var runtimeUndoMissingProfile: String { String(localized: "原配置已移除，无法撤销此操作。") }

    func canUndoRuntime(_ run: RuntimeRun) -> Bool {
        guard run.canUndo, !isArchived, let profileID = run.profileID ?? current?.profileID else { return false }
        return proxy.profiles.contains { $0.id == profileID }
    }

    /// Undoes one runtime turn from its own card.
    func undoRuntime(turnID: UUID) {
        guard let id = current?.id, let run = runtimeRun(id, turnID), canUndoRuntime(run),
              !isReversing, !changes.undoIfNext(turnID) else { return }
        undoRuntime(sessionID: id, turnID: turnID)
        changes.forget(turnID)
    }
    /// A turn's files live only as long as this launch, and it means little without them.
    func canRetry(_ turn: Turn) -> Bool { !isArchived && (turn.attachments?.isEmpty != false || sentAttachments[turn.id] != nil) }

    var canRedo: Bool { current?.turns.contains { $0.proposal?.status == .undone } == true && !isRunning && !isArchived && !isReversing }

    func retry(turnID: UUID, useLocal: Bool = false) {
        guard let turn = current?.turns.first(where: { $0.id == turnID }) else { return }
        if useLocal { useAI = false }
        send(turn.prompt, attachments: useLocal ? [] : sentAttachments[turnID] ?? [])
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
        let models = try await modelClient.listModels(settings: current, apiKey: apiKey)
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

    func showToast(_ message: String, undoable: Bool = false, warning: Bool = false, recordedIn: UUID? = nil) {
        toastWork?.cancel()
        toast = Toast(message: message, undoable: undoable, warning: warning, recordedIn: recordedIn)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func announce(_ text: String) {
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }

    func message(for error: Error) -> String {
        if let editor = error as? EditorError { return editor.message }
        if let failure = error as? AIFailure { return failure.message }
        return String(localized: "发生未知错误，请重试。")
    }
}
