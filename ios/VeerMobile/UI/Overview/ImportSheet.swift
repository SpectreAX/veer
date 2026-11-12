import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ImportSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosingFile = false
    @State private var succeeded = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $store.importText)
                            .font(.subheadline.monospaced())
                            .scrollContentBackground(.hidden)
                            .padding(Spacing.s)
                            .frame(minHeight: 160)
                            .accessibilityLabel("订阅链接或配置内容")
                            .accessibilityIdentifier("import-editor")
                        if store.importText.isEmpty {
                            Text("订阅链接或配置内容").foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 16)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .background(Color.cardBackground, in: .rect(cornerRadius: Radius.editor))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(store.importing)
                    if let error = store.importError {
                        StatusBadge(kind: .failure, text: error, font: .footnote)
                            .accessibilityIdentifier("import-error")
                    }
                    importActions
                    Text("粘贴订阅链接、Mihomo / Clash 配置、Base64 订阅内容或节点分享链接。订阅链接只保存在这台 iPhone 上，用于之后更新。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.s)
                    Button {
                        if store.importSample() { finish() }
                    } label: {
                        Label(ProxyStore.sampleProfileName, systemImage: "doc.text")
                    }
                    .buttonStyle(.secondaryCapsule)
                    .disabled(store.importing)
                    .accessibilityIdentifier("import-sample")
                }
                .padding(Spacing.l)
            }
            .background(Color.groupedBackground)
            .navigationTitle("导入配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { model.showingImport = false }
                        .labelStyle(.iconOnly).disabled(store.importing)
                        .accessibilityIdentifier("import-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: importText) {
                        if store.importing { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .buttonStyle(.borderedProminent).tint(.accentFill)
                    .disabled(store.importing || store.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("导入")
                    .accessibilityIdentifier("import-confirm")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.importing)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: fileTypes) { result in
            switch result {
            case .success(let url):
                let before = Set(store.profiles.map(\.id))
                if store.importFile(url) { activateNewProfile(before: before); finish() }
            case .failure(let error): store.importError = store.message(for: error)
            }
        }
        .sensoryFeedback(.success, trigger: succeeded)
    }

    /// Side by side when both labels fit on one line, otherwise stacked — never a label
    /// broken across two lines inside a capsule.
    private var importActions: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: Spacing.s) { pasteButton; filesButton }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) { pasteButton.lineLimit(1); filesButton.lineLimit(1) }
                    VStack(spacing: Spacing.s) { pasteButton; filesButton }
                }
            }
        }
        .disabled(store.importing)
    }

    /// The system PasteButton reads the clipboard without the "Allow Paste" prompt; reading
    /// UIPasteboard directly is refused outright once that prompt has been declined.
    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in store.importText = text; store.importError = nil }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .tint(Color.accentFill) // the system draws a white label; on grey it was unreadable
        .accessibilityIdentifier("import-paste")
    }

    private var filesButton: some View {
        // System bordered at the default size, so it is exactly as tall as the PasteButton
        // beside it (design review 2, item 1). PasteButton ignores .controlSize(.large)
        // (measured 34pt either way), so the files button follows it rather than the reverse.
        Button { choosingFile = true } label: {
            Label("从“文件”选择…", systemImage: "folder").frame(maxWidth: .infinity)
        }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
            .accessibilityIdentifier("import-files")
    }

    private var fileTypes: [UTType] {
        [.plainText] + ["yaml", "yml", "txt", "conf"].compactMap { UTType(filenameExtension: $0) }
    }
    private func importText() {
        let before = Set(store.profiles.map(\.id))
        Task {
            if await store.importFromText() { activateNewProfile(before: before); finish() }
        }
    }
    private func activateNewProfile(before: Set<UUID>) {
        if let profile = store.profiles.first(where: { !before.contains($0.id) }) { store.activate(profile.id) }
    }
    private func finish() {
        succeeded = true
        model.showingImport = false
    }
}
