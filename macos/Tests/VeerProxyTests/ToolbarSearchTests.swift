import Foundation
import Testing

/// `.searchable` on more than one page crashed the app: switching between them made NSToolbar
/// raise over a duplicate `com.apple.SwiftUI.search` item. Pages use `toolbarSearch` instead.
struct ToolbarSearchTests {
    @Test func noPageUsesTheSystemSearchItem() throws {
        let folder = LocalizationTests.root.appendingPathComponent("Sources/VeerApp")
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            if lines.contains(where: { $0.contains(".searchable(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
                found.append(url.lastPathComponent)
            }
        }
        #expect(found.isEmpty, "Use toolbarSearch: \(found)")
    }
}
