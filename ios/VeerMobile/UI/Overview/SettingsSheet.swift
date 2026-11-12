import SwiftUI
import UIKit

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(ProxyStore.self) private var proxy
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                SettingsAISection()
                Section {
                    Button("打开 iOS 设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .accessibilityIdentifier("settings-language")
                } header: {
                    Text("语言")
                } footer: {
                    Text("Veer 跟随 iPhone 的语言。要单独更改，请在 iOS“设置”的 Veer 页面里选择。")
                }
                Section {
                    HStack(spacing: Spacing.l) {
                        appIcon
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Veer").font(.title3.weight(.semibold))
                            Text("版本 \(version)").font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings-app-version")
                        }
                    }
                    .padding(.vertical, Spacing.s)
                    Text("内核：Mihomo \(proxy.coreVersion)（GPL-3.0）")
                        .accessibilityIdentifier("settings-core-version")
                    NavigationLink("第三方许可证") { LicensesView() }
                        .accessibilityIdentifier("settings-licenses")
                } header: {
                    Text("关于")
                } footer: {
                    Text("原型版，只用于在模拟器里评估，不对外发布。")
                }
                Section { MadeWithAirBuild() }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { model.showingSettings = false }
                        .labelStyle(.iconOnly).buttonStyle(.borderedProminent).tint(.accentFill)
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
        .tint(.veerAccent)
        .presentationDetents([.large])
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = iconImage {
            Image(uiImage: icon).resizable().scaledToFit()
                .frame(width: 60, height: 60)
                .clipShape(.rect(cornerRadius: Radius.change))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title).foregroundStyle(Color.veerAccent)
                .frame(width: 60, height: 60)
                .background(Color.quietFill, in: .rect(cornerRadius: Radius.change))
                .accessibilityHidden(true)
        }
    }
    private var iconImage: UIImage? {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        return files?.last.flatMap { UIImage(named: $0) }
    }
}

struct LicensesView: View {
    private let components: [(name: String, license: String, resource: String, source: String)] = [
        ("Mihomo", "GPL-3.0", "Mihomo-License", "https://github.com/MetaCubeX/mihomo"),
        ("Yams", "MIT", "Yams-License", "https://github.com/jpsim/Yams")
    ]
    var body: some View {
        List {
            ForEach(components, id: \.name) { component in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            Text("\(component.name) · \(component.license)").font(.headline)
                            if let url = Bundle.main.url(forResource: component.resource, withExtension: "txt"),
                               let text = try? String(contentsOf: url, encoding: .utf8) {
                                Text(text).font(.code).textSelection(.enabled)
                            }
                            if let url = URL(string: component.source) {
                                Link(component.source, destination: url).font(.footnote)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.l)
                    }
                    .navigationTitle(component.name)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    OverviewValueRow(title: component.name, value: component.license).padding(-Spacing.l)
                }
                .accessibilityIdentifier("license-\(component.name.lowercased())")
            }
        }
        .navigationTitle("第三方许可证")
        .navigationBarTitleDisplayMode(.inline)
    }
}
