import Foundation
import VeerEditor

/// One row in the composer's `/` or `@` menu.
struct CompletionItem: Identifiable, Equatable {
    enum Kind { case command, service, exit }
    let kind: Kind
    let label: String
    let hint: String
    /// Text that replaces the trigger token. `nil` for actions that do not insert text.
    let insert: String?
    var opensDomainTest = false
    var id: String { "\(kind)-\(label)" }
    var symbol: String {
        switch kind { case .command: "slash.circle"; case .service: "at"; case .exit: "arrow.triangle.branch" }
    }
}

/// The `/` or `@` token immediately before the caret, in UTF-16 offsets for NSTextView.
struct CompletionTrigger: Equatable {
    let character: Character
    let query: String
    let range: NSRange
}

struct CompletionState: Equatable {
    var trigger: CompletionTrigger
    var items: [CompletionItem]
    var index = 0
}

let completionCommands: [CompletionItem] = [
    .init(kind: .command, label: "路由", hint: "服务 走 出口", insert: "走 "),
    .init(kind: .command, label: "直连", hint: "不经代理", insert: "直连"),
    .init(kind: .command, label: "屏蔽", hint: "拒绝连接", insert: "屏蔽"),
    .init(kind: .command, label: "删除", hint: "移除已有规则", insert: "删除 "),
    .init(kind: .command, label: "检查", hint: "在检查器中测试域名", insert: nil, opensDomainTest: true),
]

func completionTrigger(in text: String, caret: Int) -> CompletionTrigger? {
    let ns = text as NSString
    guard caret >= 0, caret <= ns.length else { return nil }
    var start = caret
    while start > 0 {
        let previous = ns.substring(with: NSRange(location: start - 1, length: 1))
        if previous == "/" || previous == "@" {
            let before = start - 1
            // A trigger starts the text or follows whitespace, so "a@b" and URLs are ignored.
            if before > 0, let scalar = ns.substring(with: NSRange(location: before - 1, length: 1)).unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            return CompletionTrigger(character: Character(previous), query: ns.substring(with: NSRange(location: start, length: caret - start)),
                                     range: NSRange(location: before, length: caret - before))
        }
        if previous.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) { return nil }
        start -= 1
    }
    return nil
}

func completionItems(for trigger: CompletionTrigger, groups: [StrategyGroup]) -> [CompletionItem] {
    let candidates: [CompletionItem]
    if trigger.character == "/" {
        candidates = completionCommands
    } else {
        let services = serviceCatalog.map { CompletionItem(kind: .service, label: $0.name, hint: "\($0.domains.count) 个域名", insert: $0.name) }
        let exits = groups.map { group in
            CompletionItem(kind: .exit, label: group.name, hint: declaredRegions.first { $0.0 == group.region }?.1 ?? group.region, insert: group.name)
        }
        let builtins = [CompletionItem(kind: .exit, label: "DIRECT", hint: "直连", insert: "DIRECT"), CompletionItem(kind: .exit, label: "REJECT", hint: "屏蔽", insert: "REJECT")]
        candidates = services + exits + builtins
    }
    let query = trigger.query.lowercased()
    return Array(candidates.filter { query.isEmpty || $0.label.lowercased().contains(query) || $0.hint.lowercased().contains(query) }.prefix(8))
}

/// Replace the trigger token with the item's text; returns the new text and caret (UTF-16).
func applyCompletion(_ item: CompletionItem, to text: String, trigger: CompletionTrigger) -> (text: String, caret: Int) {
    let insert = item.insert ?? ""
    let spaced = insert.isEmpty || insert.hasSuffix(" ") ? insert : insert + " "
    let replaced = (text as NSString).replacingCharacters(in: trigger.range, with: spaced)
    return (replaced, trigger.range.location + (spaced as NSString).length)
}
