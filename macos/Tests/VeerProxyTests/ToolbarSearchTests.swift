import Foundation
import Testing

/// Two system pieces that crashed the app. `.searchable` on more than one page: switching between
/// them made NSToolbar raise over a duplicate `com.apple.SwiftUI.search` item; pages use
/// `ToolbarSearchField`. `.inspector`: changing it again before its collapse finished made AppKit raise
/// over a removed view; the Agent panel is `AgentPanelColumn`.
struct ToolbarSearchTests {
    @Test func noPageUsesTheCrashingSystemPieces() throws {
        let folder = LocalizationTests.root.appendingPathComponent("Sources/VeerApp")
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            if lines.contains(where: { ($0.contains(".searchable(") || $0.contains(".inspector(")) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
                found.append(url.lastPathComponent)
            }
        }
        #expect(found.isEmpty, "Use ToolbarSearchField or AgentPanelColumn: \(found)")
    }
}
