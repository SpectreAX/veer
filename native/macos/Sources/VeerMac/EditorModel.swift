import AppKit
import Observation
import UniformTypeIdentifiers
import VeerEditor

@Observable
final class EditorModel {
    var section: WorkbenchSection? = .editor
    var session = DraftSession()
    var prompt = "" { didSet { if prompt != oldValue { invalidatePreview() } } }
    var mode = "local" { didSet { if mode != oldValue { invalidatePreview() } } }
    var settings = AISettings()
    var groupName = ""
    var groupRegion = "UNKNOWN"
    var status = "" { didSet { statusGeneration += 1 } }
    private(set) var statusGeneration = 0
    var keyMessage = "检查钥匙串时只恢复状态，不读取秘密到界面。"
    var isError = false
    // Inline recovery remains available after transient feedback disappears.
    var issue: String?
    var busy = false
    var ruleCount: Int?
    var showingImport = false
    var importURL = ""
    private(set) var importedSource: String?
    private(set) var importedName = ""
    private var importedFileURL: URL?
    var hasDocument: Bool { importedSource != nil }
    var conversation: [ConversationTurn] = []
    var conversationScroll = ConversationScrollState()
    var review = ConversationReviewState()
    var reviewedTurn: ConversationTurn? { conversation.first { $0.id == review.selectedTurnID } }
    func openReview(_ id: UUID) {
        guard conversation.contains(where: { $0.id == id && $0.preview != nil }) else { return }
        review.open(id)
    }
    func toggleReview() {
        if review.isPresented { review.close() }
        else { review.open(reviewedTurn?.id ?? conversation.last(where: { $0.preview != nil })?.id) }
    }
    func setRouteDisclosure(_ id: UUID, group: RoutingReviewGroup.ID, expanded: Bool) {
        updateTurn(id) { if expanded { $0.expandedRoutes.insert(group) } else { $0.expandedRoutes.remove(group) } }
    }
    func confirmTurn(_ id: UUID) { guard canConfirmTurn(id) else { return }; confirm() }
    func discardTurn(_ id: UUID) { guard canConfirmTurn(id) else { return }; discard() }
    func canUndoTurn(_ id: UUID) -> Bool {
        guard !busy, session.canUndo, let turn = conversation.first(where: { $0.id == id }),
              turn.state == .confirmed, let token = turn.undoToken else { return false }
        return token == session.undoToken
    }
    func undoTurn(_ id: UUID) { guard canUndoTurn(id) else { return }; undo() }
    private var activeTurn: UUID?
    private func invalidatePreview() {
        session.invalidate()
        for index in conversation.indices { conversation[index].invalidate() }
    }
    private func updateTurn(_ id: UUID, _ update: (inout ConversationTurn) -> Void) {
        guard let index = conversation.firstIndex(where: { $0.id == id }) else { return }
        update(&conversation[index])
    }
    func canConfirmTurn(_ id: UUID) -> Bool {
        !busy && activeTurn == id && session.canConfirm && conversation.first(where: { $0.id == id })?.state == .pending
    }
    func setDisclosure(_ id: UUID, steps: Bool? = nil, diff: Bool? = nil) {
        updateTurn(id) { if let steps { $0.showsSteps = steps }; if let diff { $0.showsDiff = diff } }
    }
    func requestImport() {
        guard !busy else { return }
        if session.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "重新导入配置？"
            alert.informativeText = "导入成功后会替换当前草稿与撤销记录。请先导出需要保留的修改。导入失败时当前草稿不会改变。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "选择新配置")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        showingImport = true
    }
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var client: EditorClient
    @ObservationIgnored private let service: BundledEditorService?
    @ObservationIgnored private var keyRevision = 0

    init(client: EditorClient? = nil) {
        // Tests inject a client. The application never sends requests to this placeholder.
        self.client = client ?? (try! EditorClient(port: 4317))
        service = client == nil ? BundledEditorService(root: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("editor")) : nil
    }
    private func ensureService() async throws {
        if let service { client = try await service.start() }
        try Task.checkCancellation()
    }
    func stopService() { cancel(); service?.stop() }
    var canGenerate: Bool { hasDocument && !busy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func chooseFile() {
        guard !busy else { return }
        let revision = session.revision
        let panel = NSOpenPanel()
        panel.title = "导入 Mihomo 配置"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        perform("正在导入配置…") {
            guard await panel.begin() == .OK, let url = panel.url else { self.status = "已取消导入。"; return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ConfigurationImport.maximumBytes else { throw EditorFailure("配置超过 2 MB。") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let yaml = try ConfigurationImport.decode(try handle.read(upToCount: ConfigurationImport.maximumBytes + 1) ?? Data())
            try await self.acceptImport(yaml, name: url.lastPathComponent, revision: revision, fileURL: url)
        }
    }
    func importSubscription() {
        let address = importURL, revision = session.revision
        perform("正在下载并解析配置…") {
            let yaml = try await ConfigurationImport.download(address)
            try await self.acceptImport(yaml, name: "订阅配置.yaml", revision: revision)
        }
    }
    func acceptImport(_ yaml: String, name: String, revision: Int, fileURL: URL? = nil) async throws {
        let draft = try await client.importDocument(yaml)
        try requireCurrent(revision)
        session.loadDocument(draft); importedSource = yaml; importedName = name
        importedFileURL = fileURL
        prompt = ""; importURL = ""; showingImport = false; section = .editor
        conversation = []
        conversationScroll = ConversationScrollState()
        review = ConversationReviewState()
        ruleCount = nil; status = "导入成功，现在可以对话修改规则。地区根据名称推断，未实测。"
    }
    func setRules(_ rules: String) {
        guard !busy, rules != session.draft.rules else { return }
        for index in conversation.indices { conversation[index].invalidate() }
        session.editRules(rules); ruleCount = nil
    }
    func setBaseURL(_ url: String) {
        guard url != settings.baseUrl else { return }
        settings.baseUrl = url; settings.apiKey = ""; settings.useSavedKey = false
        keyRevision += 1
        invalidatePreview(); keyMessage = "API 地址已改变，正在检查对应 Key。"
    }
    func setModel(_ model: String) { settings.model = model; invalidatePreview() }
    func setKey(_ key: String) { settings.apiKey = key; invalidatePreview() }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; isError = false; issue = nil; status = message; session.endEditing()
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await self.ensureService(); try await action() }
            catch is CancellationError {
                status = "已取消，规则稿未改变。"
                if let id = activeTurn { updateTurn(id) { if $0.state.isRunning { $0.state = .cancelled; $0.message = "本次生成已取消，草稿未改变。" } } }
            }
            catch {
                isError = true; issue = error.localizedDescription; status = error.localizedDescription
                if let id = activeTurn { updateTurn(id) { if $0.state.isRunning { $0.state = .failed; $0.message = error.localizedDescription } } }
            }
        }
    }
    func cancel() { operation?.cancel() }
    func dismissStatus(generation: Int) {
        guard !busy, generation == statusGeneration else { return }
        status = ""
    }
    private func requireCurrent(_ revision: Int) throws {
        try Task.checkCancellation()
        guard session.revision == revision else { throw EditorFailure("输入已变化，旧结果已丢弃。请重新生成或检查。") }
    }
    func checkRules() {
        let draft = session.draft, revision = session.revision
        perform("正在检查规则片段…") {
            let info = try await self.client.inspect(draft, source: self.importedSource)
            let validation = try await self.client.validate(draft, source: self.importedSource)
            try self.requireCurrent(revision)
            self.ruleCount = info.count; self.status = validation.message
            self.isError = validation.status == "failed"
            if self.isError { self.issue = validation.message }
        }
    }
    func addGroup() {
        guard !hasDocument else { return }
        let revision = session.revision
        let group = StrategyGroup(name: groupName.trimmingCharacters(in: .whitespacesAndNewlines), region: groupRegion)
        var draft = session.draft; draft.groups.append(group)
        perform("正在验证策略组…") {
            let info = try await self.client.inspect(draft, source: self.importedSource)
            try self.requireCurrent(revision)
            self.session.replace(draft); self.ruleCount = info.count; self.groupName = ""
            self.status = "组名已登记，仅留在本机；AI 使用匿名出口。"
        }
    }
    func removeGroup(_ name: String) {
        guard !hasDocument else { return }
        let revision = session.revision
        var draft = session.draft; draft.groups.removeAll { $0.name == name }
        perform("正在检查策略组引用…") {
            let info = try await self.client.inspect(draft, source: self.importedSource)
            try self.requireCurrent(revision)
            self.session.replace(draft); self.ruleCount = info.count
            self.status = "已移除策略组；可撤销。"
        }
    }
    func loadDemo() {
        guard !hasDocument else { return }
        var draft = session.draft
        draft.groups = [.init(name: "日本出口", region: "JP"), .init(name: "美国出口", region: "US")]
        let revision = session.revision
        perform("正在检查演示组名…") {
            let info = try await self.client.inspect(draft)
            try self.requireCurrent(revision)
            self.session.replace(draft); self.ruleCount = info.count
            self.status = "已载入演示组名，非真实配置；请按实际客户端修改。"
        }
    }
    func setRegion(_ region: String, for name: String) {
        guard !busy, let index = session.draft.groups.firstIndex(where: { $0.name == name }) else { return }
        var draft = session.draft
        draft.groups[index] = StrategyGroup(name: name, region: region)
        invalidatePreview(); session.replace(draft)
    }
    func generate() {
        guard canGenerate else { return }
        let draft = session.draft
        let prompt = prompt, mode = mode, settings = settings
        self.prompt = ""
        let expected = session.revision
        var turn = ConversationTurn(prompt: prompt, mode: mode, fileName: importedName, groups: draft.groups)
        turn.steps = ["已准备本机草稿与指令；本机服务负责匿名化 AI 上下文，节点和密钥不发送给 AI。"]
        let id = turn.id
        conversation.append(turn); activeTurn = id
        conversationScroll.resume()
        perform("正在生成并校验修改，规则稿保持不变…") {
            self.updateTurn(id) { $0.state = .requesting; $0.steps.append(mode == "ai" ? "已发送 AI 请求，等待本机服务返回生成与校验结果。" : "已请求本地解析，等待生成与校验结果。") }
            let result = try await self.client.generate(draft, prompt: prompt, mode: mode, settings: settings, source: self.importedSource)
            try self.requireCurrent(expected)
            self.updateTurn(id) { $0.state = .reviewing }
            self.session.receive(result, revision: expected)
            self.updateTurn(id) {
                $0.preview = result
                $0.diffLines = conversationDiffLines(result.diff)
                $0.steps.append("已收到规则差异与校验结果：" + result.validation.message)
                $0.state = result.validation.status == "failed" ? .failed : result.changed ? .pending : .unchanged
                $0.message = result.validation.status == "failed" ? "规则检查失败，不能确认。" : result.changed ? "已准备 \(result.summaries.count) 条规则修改，等待你确认。" : "规则已存在，无需修改。"
            }
            if self.conversationScroll.following { self.review.open(id) }
            self.status = result.validation.status == "failed" ? "规则测试失败，不能确认。" : result.changed ? "预览已生成，尚未确认到规则稿。" : "规则已存在，无需修改。"
            self.isError = result.validation.status == "failed"
            if self.isError { self.issue = result.validation.message }
        }
    }
    func confirm() {
        guard let id = activeTurn, canConfirmTurn(id), session.confirm() else { return }
        let token = session.undoToken
        updateTurn(id) { $0.state = .confirmed; $0.undoToken = token; $0.message = "已写入草稿，尚未应用到代理。" }
        prompt = ""
        ruleCount = nil; status = "已确认到规则稿，尚未应用到代理。"; isError = false; issue = nil
    }
    func discard() {
        guard !busy else { return }
        if let id = activeTurn { updateTurn(id) { if $0.state == .pending { $0.state = .discarded; $0.message = "用户放弃，未写入草稿。" } } }
        session.invalidate(); status = "预览已放弃，规则稿未改变。"; isError = false; issue = nil
    }
    func undo() {
        let token = session.undoToken
        guard !busy, session.undo() else { return }
        for index in conversation.indices {
            conversation[index].invalidate()
            if conversation[index].state == .confirmed, let token, conversation[index].undoToken == token {
                conversation[index].state = .undone; conversation[index].message = "已撤销该次修改，草稿恢复到上一快照。"
            }
        }
        ruleCount = nil; status = "已撤销草稿修改。"; isError = false; issue = nil
    }
    func restoreKeyStatus() async {
        let url = settings.baseUrl, revision = keyRevision
        do {
            try await ensureService()
            let result = try await client.keyStatus(url)
            try Task.checkCancellation()
            guard url == settings.baseUrl, revision == keyRevision else { return }
            settings.useSavedKey = result.saved
            keyMessage = result.saved ? "已找到此地址的钥匙串 Key，无需重新填写。" : "未保存 Key；可填写会话 Key 或保存到钥匙串。"
        } catch {
            guard url == settings.baseUrl, revision == keyRevision, !Task.isCancelled else { return }
            settings.useSavedKey = false; keyMessage = error.localizedDescription
        }
    }
    func saveKey() {
        guard !busy else { return }
        keyRevision += 1
        let captured = settings
        perform("正在保存至 macOS 钥匙串…") {
            _ = try await self.client.saveKey(captured)
            try Task.checkCancellation()
            if captured.baseUrl == self.settings.baseUrl {
                if captured.apiKey == self.settings.apiKey { self.settings.apiKey = "" }
                self.settings.useSavedKey = true
                self.keyMessage = "Key 已保存；秘密不回传输入框。"
            }
            self.status = "Key 已保存到对应 API 地址的系统钥匙串。"
        }
    }
    func exportRules() {
        let draft = session.draft, revision = session.revision
        perform("正在检查导出规则…") {
            let contents: String
            if let source = self.importedSource { contents = try await self.client.exportDocument(source, draft: draft) }
            else { _ = try await self.client.inspect(draft); contents = draft.rules }
            try self.requireCurrent(revision)
            let panel = NSSavePanel()
            panel.title = self.hasDocument ? "导出修改后的完整配置" : "导出规则片段（不是完整配置）"
            panel.nameFieldStringValue = self.hasDocument ? "veer-edited.yaml" : "veer-rules-fragment.yaml"
            panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
            guard await panel.begin() == .OK, let url = panel.url else { self.status = "已取消导出。"; return }
            try self.requireCurrent(revision)
            try ConfigurationImport.verifyExportDestination(url, importedFile: self.importedFileURL)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            self.session.markRulesExported(draft.rules)
            self.status = self.hasDocument ? "已导出完整配置；原文件未覆盖。请由代理客户端校验后使用。" : "已导出 rules 片段。请由代理客户端合并并校验，勿覆盖完整配置。"
        }
    }
}
