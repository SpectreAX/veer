import SwiftUI
import VeerProxy

/// Suggestions found on this Mac, as cards. Opening one starts a new Agent conversation with
/// the facts filled in; nothing is changed until the user sends it and applies the result.
struct SuggestionCards: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent

    var body: some View {
        if !store.suggestions.isEmpty {
            VStack(spacing: Spacing.sm) {
                ForEach(store.suggestions) { card($0) }
            }
        }
    }

    private func card(_ suggestion: Suggestion) -> some View {
        let text = Self.text(suggestion)
        return HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent).font(.title3)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(text.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(text.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Button(String(localized: "问 AI")) {
                store.dismiss(suggestion)
                store.page = .agent
                agent.newThread()
                agent.ask(text.prompt)
            }
            .secondaryAction()
            Menu {
                if suggestion.host != nil {
                    Button(String(localized: "不再提示这个域名")) { store.dismiss(suggestion, forever: true) }
                }
                Button(String(localized: "这次忽略")) { store.dismiss(suggestion) }
            } label: { Image(systemName: "xmark") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
            .accessibilityLabel(String(localized: "忽略这条建议"))
        }
        .panel(padding: Spacing.md)
    }

    static func text(_ suggestion: Suggestion) -> (title: String, detail: String, prompt: String) {
        switch suggestion.kind {
        case .failing(let host, let count):
            (String(localized: "\(host) 经常连接失败"),
             String(localized: "最近 5 分钟失败了 \(count) 次。要不要让它换一个出口？"),
             String(localized: "\(host) 最近 5 分钟连接失败了 \(count) 次。帮我看看它现在走哪个出口，并换一个能用的。"))
        case .unmatched(let host, let count):
            (String(localized: "\(host) 没有匹配任何规则"),
             String(localized: "最近 10 分钟有 \(count) 次连接落到了最后的 MATCH。要不要为它加一条规则？"),
             String(localized: "\(host) 最近一直命中最后的 MATCH 规则。帮我判断它应该直连还是走代理，并加一条规则。"))
        case .slowNode(let group, let node):
            (String(localized: "“\(node)”连续测速超时"),
             String(localized: "“\(group)”正在用它。要不要换一个节点？"),
             String(localized: "“\(group)”换到延迟最低的节点"))
        }
    }
}
