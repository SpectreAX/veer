import SwiftUI
import VeerCore

struct AISettingsPane: View {
    @Environment(AgentStore.self) private var store
    @State private var key = ""
    @State private var remember = true
    @State private var testState: TestState = .idle
    @State private var keyError: String?
    @State private var fetchState: TestState = .idle
    @State private var customModel = ""

    enum TestState: Equatable { case idle, running, passed, failed(String) }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker(String(localized: "服务"), selection: Binding(get: { store.settings.provider }, set: { provider in
                    store.selectProvider(provider)
                    testState = .idle
                    fetchState = .idle
                    key = ""
                })) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .neutralControl()
                TextField(String(localized: "地址"), text: $store.settings.baseURL, prompt: Text(store.settings.provider.baseURL.isEmpty ? "https://…/v1" : store.settings.provider.baseURL))
                if store.settings.provider.needsKey { keyRow }
                LabeledContent(String(localized: "settings.ai.connection", defaultValue: "连接")) {
                    HStack {
                        if !store.aiConfigured { needsKeyNote }
                        Button(String(localized: "测试连接")) { test() }.disabled(testState == .running || !store.aiConfigured)
                            .help(store.aiConfigured ? String(localized: "发送一句固定的测试文字，确认地址、Key 和模型可用") : String(localized: "先填写并保存 API Key"))
                        status(testState, passed: String(localized: "可以连接，JSON 输出正常"))
                    }
                }
            }
            Section {
                Picker(String(localized: "模型"), selection: Binding(get: { store.settings.model }, set: { model in
                    store.settings.select(model: model)
                    testState = .idle
                })) {
                    ForEach(store.settings.models, id: \.self) { Text($0).tag($0) }
                }
                .neutralControl()
                ThinkingLevelControl(settings: $store.settings)
                LabeledContent(String(localized: "其他模型")) {
                    HStack {
                        TextField(String(localized: "其他模型"), text: $customModel, prompt: Text(String(localized: "输入模型 ID")))
                            .labelsHidden()
                            .onSubmit(useCustomModel)
                        Button(String(localized: "使用"), action: useCustomModel)
                            .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                LabeledContent(String(localized: "模型列表")) {
                    HStack {
                        if !store.aiConfigured { needsKeyNote }
                        Button(store.settings.fetchedModels.isEmpty ? String(localized: "从服务获取") : String(localized: "重新获取")) { fetch() }
                            .disabled(fetchState == .running || !store.aiConfigured)
                            .help(store.aiConfigured ? String(localized: "读取这个服务当前提供的对话模型") : String(localized: "先填写并保存 API Key"))
                        status(fetchState, passed: String(localized: "已获取 \(store.settings.fetchedModels.count) 个模型"))
                    }
                }
                Text(String(localized: "深度思考让模型先推理再回答，更擅长理解复杂指令；强度越高越慢、费用越高。DeepSeek V4、Claude、Gemini 2.5 Flash、GPT-5 可选强度，GLM 只能开关，o4-mini、R1 等推理模型始终深度思考。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            SearchSettingsSection()
            Section {
                Toggle(String(localized: "对话默认使用 AI 解析"), isOn: $store.useAI)
                Text(String(localized: "AI 回答无法使用时，Veer 会把问题发回让它修正一次。测试连接和获取模型列表不包含任何配置。地址必须是 HTTPS，本机服务可以用 HTTP。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accentCheckbox()
    }

    @ViewBuilder private var keyRow: some View {
        if store.keySaved || store.sessionKey != nil {
            LabeledContent("API Key") {
                HStack {
                    StatusBadge(kind: .success, text: store.keySaved ? String(localized: "已保存在本机") : String(localized: "仅本次运行有效"), compact: true)
                    Spacer()
                    Button(String(localized: "移除")) { store.forgetKey(); testState = .idle }
                }
            }
        } else {
            KeyEntryRow(provider: store.settings.provider.title, key: $key, remember: $remember, error: keyError, save: saveKey)
        }
    }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try store.saveKey(key, remember: remember)
            key = ""
            keyError = nil
            testState = .idle
        } catch {
            keyError = store.message(for: error)
        }
    }

    /// Why the buttons next to it are disabled.
    private var needsKeyNote: some View {
        Text(String(localized: "先保存 API Key")).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func status(_ state: TestState, passed: String) -> some View {
        switch state {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed: StatusBadge(kind: .success, text: passed, compact: true)
        case .failed(let message): StatusBadge(kind: .failure, text: message, compact: true).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func useCustomModel() {
        let model = customModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        store.settings.select(model: model)
        customModel = ""
        testState = .idle
    }

    private func test() {
        testState = .running
        let settings = store.settings, key = store.apiKey
        Task {
            do {
                try await AIClient().testConnection(settings: settings, apiKey: key)
                testState = .passed
            } catch {
                testState = .failed(store.message(for: error))
            }
        }
    }

    private func fetch() {
        fetchState = .running
        Task {
            do {
                _ = try await store.fetchModels()
                fetchState = .passed
            } catch {
                fetchState = .failed(store.message(for: error))
            }
        }
    }
}

/// Whether the AI may search, and where. The rule-set catalog is always part of a search.
struct SearchSettingsSection: View {
    @Environment(AgentStore.self) private var store
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle(String(localized: "允许 AI 联网搜索"), isOn: $store.searchSettings.enabled)
                .accentCheckbox()
            Picker(String(localized: "搜索服务"), selection: $store.searchSettings.provider) {
                ForEach(SearchProvider.allCases) { Text($0.title).tag($0) }
            }
            .neutralControl()
            .disabled(!store.searchSettings.enabled)
            if store.searchSettings.provider.needsURL {
                TextField(String(localized: "SearXNG 地址"), text: $store.searchSettings.searxngURL, prompt: Text("http://127.0.0.1:8888"))
                    .disabled(!store.searchSettings.enabled)
            }
            if let service = store.searchSettings.provider.aiServiceKey {
                let hasKey = store.hasKey(for: service)
                LabeledContent(String(localized: "搜索 API Key")) {
                    if hasKey {
                        StatusBadge(kind: .success, text: String(localized: "使用「\(service.title)」的 API Key"), compact: true)
                    } else {
                        Text(String(localized: "先在上方 AI 服务中保存「\(service.title)」的 API Key")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if store.searchSettings.provider.needsKey {
                if keySaved {
                    LabeledContent(String(localized: "搜索 API Key")) {
                        HStack {
                            StatusBadge(kind: .success, text: String(localized: "已保存在本机"), compact: true)
                            Spacer()
                            Button(String(localized: "移除")) { store.keyStore.delete(for: store.searchSettings.provider.keyAccount); refresh() }
                        }
                    }
                } else {
                    SecureField(String(localized: "搜索 API Key"), text: $key, prompt: Text(store.searchSettings.provider.keyPlaceholder))
                        .onSubmit(save)
                    HStack {
                        Spacer()
                        Button(String(localized: "保存"), action: save).buttonStyle(.borderedProminent).tint(.accentFill)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if let note = store.searchSettings.provider.costNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(localized: "AI 不确定某个服务对应哪个规则集、或需要网站的官方域名时，会先请求搜索：Veer 在 MetaCubeX 的全部规则集名称和所选服务中查找，把结果交给 AI。每条指令最多搜索 2 次，查询词与结果都会显示在对话里。"))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "联网搜索"))
        }
        .onAppear(perform: refresh)
        .onChange(of: store.searchSettings.provider) { key = ""; refresh() }
    }

    private func refresh() {
        let provider = store.searchSettings.provider
        keySaved = provider.needsKey && store.keyStore.read(for: provider.keyAccount) != nil
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? store.keyStore.save(trimmed, for: store.searchSettings.provider.keyAccount)
        key = ""
        refresh()
    }
}

/// Entering a key: a form field like 地址, then "remember" and Save on the next row.
struct KeyEntryRow: View {
    let provider: String
    @Binding var key: String
    @Binding var remember: Bool
    let error: String?
    let save: () -> Void

    var body: some View {
        SecureField("API Key", text: $key, prompt: Text("sk-**********"))
            .onSubmit(save)
            .accessibilityLabel(String(localized: "\(provider) 的 API Key"))
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                Toggle(String(localized: "记住 API Key"), isOn: $remember)
                    .accentCheckbox()
                Spacer()
                Button(String(localized: "保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentFill)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.statusFailure)
            }
            Text(remember ? String(localized: "保存在本机，只有你的用户账户可以读取。") : String(localized: "只在本次运行有效，退出后需要重新填写。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Thinking strength for the selected model: a slider when it can change, otherwise a note.
struct ThinkingLevelControl: View {
    @Binding var settings: AISettings

    var body: some View {
        let style = settings.thinkingStyle
        LabeledContent(String(localized: "深度思考")) {
            if style.adjustable {
                ThinkingSlider(style: style, level: Binding(get: { settings.effectiveLevel }, set: { settings.thinkingLevel = $0 }))
                    .frame(width: 240)
            } else {
                Text(style == .intrinsic ? String(localized: "始终开启（推理模型）") : String(localized: "此模型不支持")).foregroundStyle(.secondary)
            }
        }
    }
}

struct PrivacySettingsPane: View {
    @Environment(AgentStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Form {
            Section(String(localized: "发送给 AI 的内容")) {
                Label(String(localized: "匿名化的配置 YAML：策略组与节点改为“策略组N”“节点N”，只保留结构、策略组类型和声明的地区"), systemImage: "checkmark")
                Label(String(localized: "现有规则的类型与匿名出口；具体域名和 IP 默认替换为占位符"), systemImage: "checkmark")
                Label(String(localized: "你的指令，其中的出口名称会替换成匿名标签"), systemImage: "checkmark")
                Label(String(localized: "本对话最近几轮的匿名摘要，用于理解追问"), systemImage: "checkmark")
                Label(String(localized: "开启联网搜索时：AI 生成的搜索词（公开的服务或网站名称）发送给所选搜索服务，规则集目录从 GitHub 读取；包含配置标签、占位符或私有地址的搜索词会被拒绝"), systemImage: "magnifyingglass")
            }
            Section(String(localized: "查询工具")) {
                Label(String(localized: "规则集与 IP 查询在本机进行：地理数据（MetaCubeX geosite、geoip 与 GeoLite2-ASN）只在你点下载时从 GitHub 获取"), systemImage: "lock.shield")
                Label(String(localized: "DNS 查询只发给你选择的服务器；IP 页输入域名时通过阿里 DoH 解析"), systemImage: "network")
                Label(String(localized: "AI 排查问题时请 Veer 检查的域名在本机匹配规则；需要按 IP 判断时，这些公开域名会通过阿里 DoH 解析"), systemImage: "checklist")
            }
            Section(String(localized: "从不发送")) {
                Label(String(localized: "真实的节点、策略组和代理集名称"), systemImage: "xmark")
                Label(String(localized: "节点地址、端口、密码、UUID、协议与传输参数"), systemImage: "xmark")
                Label(String(localized: "订阅链接、规则集与代理集地址"), systemImage: "xmark")
                Label(String(localized: "DNS、TUN、端口、控制器等其他配置"), systemImage: "xmark")
            }
            Section {
                Toggle(String(localized: "发送现有规则中的具体域名和 IP"), isOn: Binding(get: { store.shareRuleLiterals }, set: { store.shareRuleLiterals = $0 }))
                    .accentCheckbox()
                Text(String(localized: "关闭时这些值显示为 <域名N>、<IPN>。打开后 AI 能看到你现有的分流目标，可能包含内网或个人常用域名。")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(String(localized: "每一轮 AI 对话下方都有“查看发送给 AI 的内容”，可以核对实际发送的文字。你在指令里亲自输入的秘密无法被自动识别，请勿粘贴密钥或订阅链接。"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "清除所有 Agent 对话…"), role: .destructive) { confirming = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(String(localized: "清除所有 Agent 对话？"), isPresented: $confirming) {
            Button(String(localized: "清除"), role: .destructive) { store.deleteAllSessions() }
        } message: {
            Text(String(localized: "会删除本机保存的全部对话；已经应用的修改仍在“我的分流”里。"))
        }
    }
}

/// Everything about Mihomo in one place: the bundled validator and the running core.
