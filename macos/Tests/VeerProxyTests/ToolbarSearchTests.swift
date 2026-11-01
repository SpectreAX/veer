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

    /// As the sidebar opens the toolbar runs short of room for a few frames and moves items into an
    /// overflow button, which threw the capsule aside; the main window's toolbar stays empty.
    @Test func theMainWindowsToolbarHasNoItems() throws {
        let file = LocalizationTests.root.appendingPathComponent("Sources/VeerApp/MainView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("ToolbarItem("))
        #expect(source.contains(".toolbar(removing: .sidebarToggle)"))
    }

    /// In full screen AppKit puts the toolbar in a window of its own, over this one, which hid every
    /// control floating in the top row. It comes off there, with the row kept by `MainView`.
    @Test func theToolbarGetsOutOfTheWayInFullScreen() throws {
        let folder = LocalizationTests.root.appendingPathComponent("Sources/VeerApp")
        let main = try String(contentsOf: folder.appendingPathComponent("MainView.swift"), encoding: .utf8)
        #expect(main.contains("window?.toolbar = fullScreen ? nil : toolbar"))
        #expect(main.contains("isFullScreen ? Self.topRowHeight : 0"))
    }

    /// ⌘F found the field by the content area's top, which in full screen is the window's own.
    @Test func searchFocusDoesNotDependOnTheToolbar() throws {
        let file = LocalizationTests.root.appendingPathComponent("Sources/VeerApp/ToolbarSearch.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("contentLayoutRect"))
    }
}
