import AppKit
import SwiftUI
import Testing
@testable import VeerUI

/// The pull-down makes its items only as its menu opens, from what is true then, and keeps its
/// title item first.
@MainActor struct LazyPullDownTests {
    static let entries: [PullDownEntry] = [
        PullDownEntry(title: "DIRECT    —", kind: .item(id: "DIRECT")),
        .separator,
        PullDownEntry(title: "🇯🇵 Japan · 2 · 92 ms", checked: true, kind: .submenu([
            PullDownEntry(title: "Tokyo    92 ms", checked: true, kind: .item(id: "Tokyo")),
            PullDownEntry(title: "Osaka    412 ms", kind: .item(id: "Osaka")),
        ])),
    ]

    @Test func itemsAreMadeAsTheMenuOpensAndChooseByID() throws {
        var made = 0, chosen: [String] = []
        let coordinator = LazyPullDown.Coordinator()
        coordinator.entries = {
            made += 1
            return Self.entries
        }
        coordinator.choose = { chosen.append($0) }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "→ Tokyo", action: nil, keyEquivalent: ""))
        #expect(made == 0)

        coordinator.menuNeedsUpdate(menu)
        #expect(made == 1)
        #expect(menu.items.map(\.title) == ["→ Tokyo", "DIRECT    —", "", "🇯🇵 Japan · 2 · 92 ms"])
        #expect(menu.items[2].isSeparatorItem)
        let japan = menu.items[3]
        #expect(japan.state == .on)
        let submenu = try #require(japan.submenu)
        #expect(submenu.items.map(\.title) == ["Tokyo    92 ms", "Osaka    412 ms"])
        #expect(submenu.items.map(\.state) == [.on, .off])

        // Opening again makes them again rather than adding to them.
        coordinator.menuNeedsUpdate(menu)
        #expect(made == 2 && menu.items.count == 4)

        coordinator.chosen(submenu.items[1])
        coordinator.chosen(menu.items[1])
        #expect(chosen == ["Osaka", "DIRECT"])
        #expect(submenu.items[1].target === coordinator && submenu.items[1].action != nil)
    }

    @Test func theButtonIsABorderlessPullDownThatTruncates() throws {
        let view = NSHostingView(rootView: LazyPullDown(title: "→ A node with a very long name indeed", font: .callout, help: "Switch node",
                                                        label: "Node used by “Proxy”", value: "A node", entries: { [] }, choose: { _ in })
                .frame(width: 120))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        view.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSPopUpButton] { ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        let button = try #require(buttons(view).first)
        #expect(button.pullsDown && !button.isBordered)
        #expect(button.title == "→ A node with a very long name indeed")
        #expect(button.toolTip == "Switch node")
        // On the cell too, the element VoiceOver reaches: the group, then the node, never the arrow.
        let cell = try #require(button.cell)
        for element in [button as NSObject & NSAccessibilityProtocol, cell] {
            #expect(element.accessibilityLabel() == "Node used by “Proxy”")
            #expect(element.accessibilityTitle() == "Node used by “Proxy”")
            #expect(element.accessibilityValue() as? String == "A node")
        }
        // The open menu stays the system's menu size whatever the title's font.
        #expect(button.menu?.font.pointSize == NSFont.menuFont(ofSize: 0).pointSize)
        #expect((button.cell as? NSPopUpButtonCell)?.lineBreakMode == .byTruncatingTail)
        // SwiftUI lays out the alignment rectangle, inside the button's own frame: the width given, not its own.
        #expect(button.intrinsicContentSize.width > 120)
        #expect(button.alignmentRect(forFrame: button.frame).width <= 120)
        #expect(button.menu?.delegate != nil)
    }
}

/// Rows of equal columns for the lazy grid: chunks, widths and the short last row.
@MainActor struct SteadyRowsTests {
    @Test func itemsChunkIntoRowsWithAShortLastOne() {
        let rows = SteadyColumns<EmptyView>.rows(Array(1...10), columns: 4)
        #expect(rows.map(Array.init) == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
        #expect(SteadyColumns<EmptyView>.rows([Int](), columns: 4).isEmpty)
        #expect(SteadyColumns<EmptyView>.rows([1, 2], columns: 0).map(Array.init) == [[1], [2]])
    }

    @Test func aRowGivesEveryColumnTheSameWidthEvenWhenShort() throws {
        #expect(EqualColumnsRow.columnWidth(400, columns: 4, spacing: 8) == 94)
        let view = NSHostingView(rootView: EqualColumnsRow(columns: 4, spacing: 8) {
            Color.red.frame(minHeight: 20)
            Color.green.frame(minHeight: 30)
        }.frame(width: 400))
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        #expect(size.height == 30, "as tall as the tallest")
    }
}

/// The count follows the width it is given, also back up again after a narrower layout.
@MainActor struct SteadyColumnsTests {
    @Observable final class Seen { var count = 0 }
    @Observable final class Width { var value: CGFloat = 712 }

    @Test func theCountFollowsTheWidthDownAndBackUp() async throws {
        let seen = Seen(), width = Width()
        struct Host: View {
            let seen: Seen
            let width: Width
            var body: some View {
                SteadyColumns(minimum: 180, spacing: 8, inset: 16) { count in
                    Color.clear.frame(height: 10).onChange(of: count, initial: true) { seen.count = count }
                }
                .frame(width: width.value)
            }
        }
        let view = NSHostingView(rootView: Host(seen: seen, width: width))
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 100)
        func settle() async throws {
            for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        for (value, expected) in [(712.0, 3), (512.0, 2), (612.0, 3), (587.0, 2), (588.0, 3)] {
            width.value = value
            try await settle()
            #expect(seen.count == expected, "\(value) pt")
        }
    }
}
