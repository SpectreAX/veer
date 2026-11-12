import SwiftUI

struct OverviewTab: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var modeFeedback = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.activeProfile == nil { welcome } else { overview }
            }
            .background(Color.groupedBackground)
            .navigationTitle("概览")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { model.showingSettings = true }
                        .labelStyle(.iconOnly)
                        .tint(.primary)
                        .accessibilityIdentifier("overview-settings")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: modeFeedback)
        .sensoryFeedback(.success, trigger: store.isRunning) { _, running in running }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("欢迎使用 Veer", systemImage: "tray.and.arrow.down")
        } description: {
            Text("先添加你的订阅。粘贴订阅链接，或者从“文件”选择一个 Mihomo / Clash 配置文件。订阅链接只保存在这台 iPhone 上。")
        } actions: {
            Button("导入配置…", action: openImport)
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("overview-import")
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                OverviewHero()
                Text("内核只在 Veer 里运行，不接管 iPhone 的网络。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("overview-prototype-note")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("模式").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                    Picker("模式", selection: Binding(get: { store.mode }, set: {
                        store.setMode($0)
                        modeFeedback += 1
                    })) {
                        ForEach(ProxyStore.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!store.isRunning)
                    .opacity(store.isRunning ? 1 : 0.45)
                    .accessibilityIdentifier("overview-mode")
                }
                .padding(.top, Spacing.l)
                traffic
                details.padding(.top, Spacing.l)
                if let notice = store.notice {
                    StatusBadge(kind: .failure, text: notice, font: .footnote)
                        .padding(.horizontal, Spacing.l)
                        .accessibilityIdentifier("overview-error")
                }
            }
            .padding(Spacing.l)
        }
    }

    private var traffic: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Spacing.s)) : AnyLayout(HStackLayout(spacing: Spacing.s))
        // Both cards share one header layout: peak beside the label when both fit, else below.
        return ViewThatFits(in: .horizontal) {
            layout {
                OverviewTrafficCard(upload: true, inlinePeak: true)
                OverviewTrafficCard(upload: false, inlinePeak: true)
            }
            layout {
                OverviewTrafficCard(upload: true, inlinePeak: false)
                OverviewTrafficCard(upload: false, inlinePeak: false)
            }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(store.profiles) { profile in
                    Button { store.activate(profile.id) } label: {
                        if profile.id == store.activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else { Text(profile.name) }
                    }
                    .accessibilityIdentifier("overview-select-profile-\(profile.id.uuidString.lowercased())")
                }
                Divider()
                Button("更新订阅") {
                    if let id = store.activeProfileID { store.update(id) }
                }
                .disabled(!canUpdate || updating)
                .accessibilityIdentifier("overview-profile-update")
                Button("导入配置…", action: openImport)
                    .accessibilityIdentifier("overview-profile-import")
            } label: {
                OverviewValueRow(title: String(localized: "使用的配置"), value: store.activeProfile?.name ?? "—", symbol: "chevron.up.chevron.down")
            }
            .accessibilityIdentifier("overview-profile")
            Divider().padding(.leading, Spacing.l)
            NavigationLink {
                ConnectionsView()
            } label: {
                OverviewValueRow(title: String(localized: "连接"), value: store.isRunning ? String(localized: "\(store.connectionCount) 个连接") : "—", symbol: "chevron.right")
            }
            .accessibilityIdentifier("overview-connections")
            Divider().padding(.leading, Spacing.l)
            OverviewValueRow(title: String(localized: "内核版本"), value: "Mihomo \(store.coreVersion)")
                .accessibilityIdentifier("overview-core-version")
        }
        .background(Color.cardBackground, in: .rect(cornerRadius: Radius.hero))
        .buttonStyle(.plain)
    }

    private var canUpdate: Bool { store.activeProfileID.map(store.canUpdate) ?? false }
    private var updating: Bool { store.activeProfileID.map { store.updatingProfiles.contains($0) } ?? false }
    private func openImport() {
        store.openImport()
        model.showingImport = true
    }
}

struct OverviewValueRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: Spacing.s) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout(spacing: Spacing.m))
            layout {
                Text(title).foregroundStyle(.primary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
            if let symbol {
                Image(systemName: symbol).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.body)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct OverviewTrafficCard: View {
    @Environment(ProxyStore.self) private var store
    let upload: Bool
    let inlinePeak: Bool
    private var rate: Int64 { upload ? store.uploadRate : store.downloadRate }
    private var peak: Int64 { upload ? store.uploadPeak : store.downloadPeak }
    private var total: Int64 { upload ? store.uploadTotal : store.downloadTotal }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if inlinePeak {
                HStack(spacing: Spacing.xs) { heading.fixedSize(); Spacer(minLength: Spacing.xs); peakLabel.fixedSize() }
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) { heading; peakLabel }
            }
            Text(store.isRunning ? OverviewFormat.rate(rate) : "—")
                .font(.title3.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
                .foregroundStyle(store.isRunning ? Color.primary : Color.secondary)
                .accessibilityIdentifier(upload ? "overview-upload-rate" : "overview-download-rate")
            if store.isRunning {
                Text("本次共 \(OverviewFormat.bytes(total))").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(upload ? "overview-upload-total" : "overview-download-total")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground, in: .rect(cornerRadius: Radius.hero))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(upload ? "overview-upload" : "overview-download")
    }
    private var heading: some View {
        Label(upload ? String(localized: "上传") : String(localized: "下载"), systemImage: upload ? "arrow.up" : "arrow.down")
            .font(.footnote).foregroundStyle(.secondary)
    }
    @ViewBuilder private var peakLabel: some View {
        if store.isRunning {
            Text("峰值 \(OverviewFormat.rate(peak))").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier(upload ? "overview-upload-peak" : "overview-download-peak")
        }
    }
}

enum OverviewFormat {
    static func bytes(_ value: Int64) -> String {
        // Default formatter spells zero out ("Zero KB") and drops to bytes below 1 KB ("0 字节/s");
        // start at KB so idle and small rates read "0 KB/s" like the rest.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, value))
    }
    static func rate(_ value: Int64) -> String { "\(bytes(value))/s" }
    static func duration(_ start: Date, now: Date) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(start))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
