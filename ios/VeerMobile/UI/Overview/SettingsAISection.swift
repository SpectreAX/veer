import SwiftUI
import VeerCore

struct SettingsAISection: View {
    @Environment(AgentStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var key = ""
    @State private var keyError: String?
    @State private var confirmingRemoval = false
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var testTask: Task<Void, Never>?
    @State private var customModel = ""

    private enum TestResult { case success, failure(String) }

    var body: some View {
        if model.fixture { fixtureSection } else { serviceSection }
    }

    /// Fixture runs hold an in-memory stand-in key and model; showing them as a saved OpenAI key
    /// would misstate that an AI is connected, so the section names the sample mode only.
    private var fixtureSection: some View {
        Section {
            StatusBadge(kind: .info, text: FixtureAI.label, font: .body)
                .accessibilityIdentifier("settings-fixture")
        } header: {
            Text("AI 服务")
        }
    }

    private var serviceSection: some View {
        @Bindable var store = store
        return Section {
            Picker("服务", selection: Binding(get: { store.settings.provider }, set: {
                resetTest()
                store.selectProvider($0)
                key = ""
                keyError = nil
            })) {
                ForEach(AIProvider.allCases.filter { $0 != .ollama }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-provider")
            if store.settings.provider == .custom {
                TextField("地址", text: $store.settings.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings-base-url")
            }
            keyRow
            if let keyError {
                StatusBadge(kind: .failure, text: keyError, font: .footnote)
                    .accessibilityIdentifier("settings-key-error")
            }
            Picker("模型", selection: Binding(get: { store.settings.model }, set: {
                store.settings.select(model: $0)
                resetTest()
            })) {
                ForEach(store.settings.models, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-model")
            if store.settings.provider == .custom {
                HStack {
                    TextField("输入模型 ID", text: $customModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings-custom-model")
                    Button("使用") {
                        store.settings.select(model: customModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        customModel = ""
                        resetTest()
                    }
                    .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings-use-model")
                }
            }
            thinkingPicker
            Button(action: test) {
                HStack {
                    Text("测试连接")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || !store.aiConfigured || store.settings.model.isEmpty)
            .accessibilityIdentifier("settings-test-connection")
            if let testResult {
                switch testResult {
                case .success:
                    StatusBadge(kind: .success, text: String(localized: "可以连接，JSON 输出正常"), font: .footnote)
                        .accessibilityIdentifier("settings-test-result")
                case .failure(let message):
                    StatusBadge(kind: .failure, text: message, font: .footnote)
                        .accessibilityIdentifier("settings-test-result")
                }
            }
        } header: {
            Text("AI 服务")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("保存在这台 iPhone 上。")
                Text("发给 AI 的配置会先匿名化，服务器地址、密码和订阅链接不会发送。")
            }
        }
        .alert("移除 API Key？", isPresented: $confirmingRemoval) {
            Button("移除", role: .destructive) { store.forgetKey(); resetTest() }
                .accessibilityIdentifier("settings-confirm-remove-key")
            Button("取消", role: .cancel) {}
        }
        .onChange(of: store.settings.baseURL) { resetTest() }
        .onDisappear { testTask?.cancel() }
    }

    @ViewBuilder private var keyRow: some View {
        if store.keySaved || store.sessionKey != nil {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s)) : AnyLayout(HStackLayout(spacing: Spacing.s))
            layout {
                Text("API Key")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                StatusBadge(kind: .success, text: store.keySaved ? String(localized: "已保存在本机") : String(localized: "仅本次运行有效"), font: .footnote)
                    .accessibilityIdentifier("settings-key-status")
                Button("移除", role: .destructive) { confirmingRemoval = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings-remove-key")
            }
        } else {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s)) : AnyLayout(HStackLayout(spacing: Spacing.s))
            layout {
                SecureField("API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings-api-key")
                Button("保存", action: saveKey)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings-save-key")
            }
        }
    }

    @ViewBuilder private var thinkingPicker: some View {
        let style = store.settings.thinkingStyle
        if style.adjustable {
            Picker("深度思考", selection: Binding(get: { store.settings.effectiveLevel }, set: {
                store.settings.thinkingLevel = $0
                resetTest()
            })) {
                ForEach(style.levels) { Text(style.title(of: $0)).tag($0) }
            }
            .pickerStyle(.menu).accessibilityIdentifier("settings-thinking")
        } else {
            OverviewValueRow(title: String(localized: "深度思考"), value: style == .intrinsic ? String(localized: "始终开启（推理模型）") : String(localized: "此模型不支持"))
                .padding(-Spacing.l)
                .accessibilityIdentifier("settings-thinking")
        }
    }

    private func saveKey() {
        do {
            try store.saveKey(key, remember: true)
            key = ""
            keyError = nil
            resetTest()
        } catch { keyError = store.message(for: error) }
    }
    private func resetTest() {
        testTask?.cancel()
        testing = false
        testResult = nil
    }
    private func test() {
        testing = true
        testResult = nil
        let settings = store.settings, apiKey = store.apiKey
        let client = model.fixture ? AIClient(transport: FixtureAITransport()) : AIClient()
        testTask = Task {
            do {
                try await client.testConnection(settings: settings, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                testResult = .success
            } catch {
                guard !Task.isCancelled else { return }
                testResult = .failure(store.message(for: error))
            }
            testing = false
        }
    }
}
