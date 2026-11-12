// macOS only: it zips through Backup, and the iOS prototype has no diagnostics export.
#if os(macOS)
import Foundation
import VeerCore

/// A bundle for reporting a problem: versions, settings, the effective config with servers,
/// passwords and names replaced, and recent logs. No keys and no subscription links.
public enum Diagnostics {
    /// One file in the bundle, shown before export.
    public struct Item: Sendable, Identifiable, Equatable {
        public let name: String
        public let text: String
        public var id: String { name }
    }

    public static func collect(appVersion: String, coreVersion: String?, settings: RuntimeSettings, state: String?,
                               effectiveConfig: String?, logs: [String], coreTail: [String]) -> [Item] {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        var info = """
        Veer \(appVersion)
        Mihomo \(coreVersion ?? "unknown")
        macOS \(system)
        Architecture \(architecture)
        Language \(Locale.preferredLanguages.first ?? "unknown")
        """
        info += "\n"
        var items = [Item(name: "info.txt", text: info)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { items.append(Item(name: "settings.json", text: String(decoding: data, as: UTF8.self))) }
        if let state { items.append(Item(name: "state.json", text: state)) }
        if let effectiveConfig, let document = try? ConfigDocument.parse(effectiveConfig) {
            let regions = Dictionary(document.targets.map { ($0.name, Region.infer(from: $0.name)) }, uniquingKeysWith: { a, _ in a })
            items.append(Item(name: "config-anonymized.yaml", text: AnonymizedConfig.make(document: document, regions: regions).yaml))
        }
        items.append(Item(name: "logs.txt", text: logs.suffix(500).joined(separator: "\n")))
        if !coreTail.isEmpty { items.append(Item(name: "core-output.txt", text: coreTail.joined(separator: "\n"))) }
        return items
    }

    /// Writes the items as a zip at `destination`.
    public static func write(_ items: [Item], to destination: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("veer-diagnostics-\(UUID().uuidString)")
        let root = staging.appendingPathComponent("Veer Diagnostics")
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for item in items { try Data(item.text.utf8).write(to: root.appendingPathComponent(item.name)) }
        try? manager.removeItem(at: destination)
        try Backup.ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path])
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
#endif
