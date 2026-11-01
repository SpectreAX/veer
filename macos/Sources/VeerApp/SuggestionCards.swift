import SwiftUI
import VeerProxy

/// Suggestions found on this Mac, as cards. Opening one starts a new Agent conversation with
/// the facts filled in; nothing is changed until the user sends it and applies the result.
struct SuggestionCards: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(\.agentCompact) private var compact
    /// Cards shown before the rest fold into a link to the overview; nil shows them all. Pages
    /// without their own scroll (the Agent page) set it, or the cards push the window's content
    /// past its top edge.
    var limit: Int?

    var body: some View {
        if !store.suggestions.isEmpty {
            let shown = limit.map { Array(store.suggestions.prefix($0)) } ?? store.suggestions
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(shown) { card($0) }
                if shown.count < store.suggestions.count {
                    Button(String(localized: "还有 \(store.suggestions.count - shown.count) 条建议，在概览查看")) { store.page = .overview }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder private func card(_ suggestion: Suggestion) -> some View {
        let text = Self.text(suggestion)
        if compact {
            // The side panel: too narrow for the button beside the text, and with no scroll of
            // its own, so the text is held to a few lines.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent)
                    Text(text.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Spacing.sm)
                    dismissMenu(suggestion)
                }
                Text(text.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                askButton(suggestion, prompt: text.prompt).controlSize(.small)
            }
            .panel(padding: Spacing.md)
        } else {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent).font(.title3)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(text.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    // Held to a few lines, as in the side panel: at its full height, this card pushed the
                    // Agent page, which has no scroll of its own, past the window's top edge.
                    Text(text.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: Spacing.sm)
                askButton(suggestion, prompt: text.prompt)
                dismissMenu(suggestion)
            }
            .panel(padding: Spacing.md)
        }
    }

    private func askButton(_ suggestion: Suggestion, prompt: String) -> some View {
        Button(String(localized: "问 AI")) {
            store.dismiss(suggestion)
            agent.open(asking: prompt, fresh: true)
        }
        .secondaryAction()
    }

    private func dismissMenu(_ suggestion: Suggestion) -> some View {
        Menu {
                if suggestion.host != nil {
                    Button(String(localized: "不再提示这个域名")) { store.dismiss(suggestion, forever: true) }
                }
                Button(String(localized: "这次忽略")) { store.dismiss(suggestion) }
            } label: { Image(systemName: "xmark") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().neutralControl()
            .accessibilityLabel(String(localized: "忽略这条建议"))
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
