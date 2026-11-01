import AppKit
import ServiceManagement
import SwiftUI
import VeerProxy

/// Opening Veer at login, through SMAppService. Off until the user turns it on.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS lists Veer under Login Items but the user switched it off there.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Where people can support Veer. Empty until the accounts exist; the section stays hidden.
enum SponsorLinks {
    static let githubSponsors: URL? = nil
    static let afdian: URL? = nil
    static var all: [(title: String, url: URL)] {
        [(String(localized: "GitHub Sponsors"), githubSponsors), (String(localized: "爱发电"), afdian)].compactMap { item in item.1.map { (item.0, $0) } }
    }
}

/// Version, updates, licenses, sponsorship and the diagnostics bundle.
struct AboutSettings: View {
    @Environment(ProxyStore.self) private var store
    @State private var coreVersion: String?
    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.lg) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(verbatim: "Veer").font(.title2.weight(.semibold))
                        Text("版本 \(Self.version)").foregroundStyle(.secondary)
                        Text(verbatim: "Mihomo \(coreVersion ?? "—")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            Section {
                HStack {
                    Button(String(localized: "检查更新…")) { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.canCheck)
                    Button(String(localized: "第三方许可证")) { Self.openLicenses() }
                    Button(String(localized: "导出诊断包…")) { showingDiagnostics = true }
                    Spacer()
                }
                .neutralControl()
            }
            if !SponsorLinks.all.isEmpty {
                Section {
                    HStack {
                        ForEach(SponsorLinks.all, id: \.url) { link in
                            Link(link.title, destination: link.url)
                        }
                        Spacer()
                    }
                } header: {
                    Text(String(localized: "支持 Veer"))
                } footer: {
                    Text(String(localized: "Veer 在 macOS 上免费。如果它帮到了你，可以赞助开发。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: store.coreRevision) { coreVersion = await Self.coreVersion(store.reportedBinary) }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsSheet() }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    static func openLicenses() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("licenses") else { return }
        NSWorkspace.shared.open(folder)
    }

    /// "v1.19.29" from `mihomo -v`, read once in the background.
    static func coreVersion(_ binary: URL?) async -> String? {
        guard let binary else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-v"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // "Mihomo Meta v1.19.29 darwin arm64 with go1.24 …"
            return String(decoding: data, as: UTF8.self).split(separator: " ").first { $0.hasPrefix("v") }.map(String.init)
        }.value
    }
}
