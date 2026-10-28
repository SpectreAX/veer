import SwiftUI
import UniformTypeIdentifiers
import VeerProxy

/// Profiles: which one runs, updating subscriptions, importing and removing.
struct ProfilesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var pendingDeletion: Profile?

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                StateView(symbol: "tray.and.arrow.down", title: "还没有配置",
                          message: "支持订阅链接、Mihomo / Clash 配置文件、Base64 订阅内容和节点分享链接。",
                          actionTitle: "导入配置…") { store.openImport() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
                        ForEach(store.profiles) { profile in
                            ProfileRow(profile: profile, active: profile.id == store.activeProfileID) { pendingDeletion = profile }
                        }
                    }
                    .padding(Spacing.xl)
                    .frame(maxWidth: Metrics.readingWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.openImport() } label: { Label("导入配置", systemImage: "plus") }.help("导入配置（⌘O）")
            }
        }
        .alert("删除配置？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) { if let profile = pendingDeletion { store.delete(profile.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDeletion?.id == store.activeProfileID ? "这是正在使用的配置，删除后内核会停止。" : "配置文件和订阅链接会从本机删除。")
        }
    }
}

private struct ProfileRow: View {
    @Environment(ProxyStore.self) private var store
    let profile: Profile
    let active: Bool
    let delete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.veerAccent : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Tag(text: profile.isSubscription ? "订阅" : "本地")
                    if active { Tag(text: "使用中", tint: .statusSuccess) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            if store.updatingProfiles.contains(profile.id) { ProgressView().controlSize(.small) }
            if profile.isSubscription {
                Button("更新") { store.update(profile.id) }
                    .buttonStyle(.bordered).neutralControl()
                    .disabled(store.updatingProfiles.contains(profile.id))
            }
            if !active {
                Button("使用") { store.activate(profile.id) }.buttonStyle(.bordered).neutralControl()
            }
            Menu {
                Button("删除…", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
            .accessibilityLabel("更多操作")
        }
        .panel(padding: Spacing.md)
    }

    private var detail: String {
        var parts = ["\(profile.nodeCount) 个节点", "更新于 \(Format.relative(profile.updatedAt))"]
        if let usage = profile.usage, let total = usage.total, total > 0 {
            let used = (usage.upload ?? 0) + (usage.download ?? 0)
            parts.append("已用 \(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))")
        }
        return parts.joined(separator: " · ")
    }
}

/// One field for a subscription link or pasted content, or a file.
struct ImportSheet: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("导入配置").font(.title3.weight(.semibold))
                Text("粘贴订阅链接、Mihomo / Clash 配置、Base64 订阅内容或节点分享链接。订阅链接只保存在这台 Mac 上（仅你可读），用于之后更新。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $store.importText)
                .font(Typography.code)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color.separatorLine))
                .frame(height: 160)
                .accessibilityLabel("订阅链接或配置内容")
            if let error = store.importError {
                StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("选择文件…") { choosingFile = true }.neutralControl()
                Spacer()
                if store.importing { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("导入") { store.importFromText() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.importing)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            if case .success(let url) = result { store.importFile(url) }
        }
    }
}
