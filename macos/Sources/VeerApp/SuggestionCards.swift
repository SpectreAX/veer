import SwiftUI
import VeerProxy

/// Suggestions found on this Mac, as a stack: the most serious one as a card, the rest behind it as
/// edges with a count, as Notification Center stacks notifications. Expanding shows them all, each
/// with its own way to ask the AI or to close it. Opening one starts a new Agent conversation with
/// the facts filled in; nothing is changed until the user sends it and applies the result.
struct SuggestionCards: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(\.agentCompact) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set where the cards have no scroll of their own around them (the Agent page and panel): the
    /// expanded stack then scrolls within a height of its own, so the conversation keeps its room.
    var limit: Int?
    @State private var expanded = false

    /// How far each edge behind the first card shows, and how much narrower it is on either side.
    private static let edgeStep: CGFloat = 6, edgeInset: CGFloat = 10
    private static let expandedHeight: CGFloat = 280

    var body: some View {
        let suggestions = store.suggestions
        if let first = suggestions.first {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if suggestions.count == 1 {
                    card(first)
                } else if expanded {
                    expandedCards(suggestions)
                    Button(String(localized: "收起建议")) { toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                } else {
                    let behind = min(2, suggestions.count - 1)
                    card(first)
                        .background { edges(behind) }
                        .padding(.bottom, CGFloat(behind) * Self.edgeStep)
                    Button(String(localized: "还有 \(suggestions.count - 1) 条建议，展开查看")) { toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            // One suggestion left: nothing to expand next time.
            .onChange(of: suggestions.count) { _, count in if count < 2 { expanded = false } }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.standard) { expanded.toggle() }
    }

    @ViewBuilder private func expandedCards(_ suggestions: [Suggestion]) -> some View {
        let cards = VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(suggestions) { card($0) }
        }
        if limit != nil {
            ScrollView { cards }
                .frame(maxHeight: Self.expandedHeight)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            cards
        }
    }

    /// The cards behind the first, as the lower edge of each: the card's own fill and border, a
    /// little narrower and lower each time. No tilt and no shadow.
    private func edges(_ count: Int) -> some View {
        ZStack {
            ForEach((1...max(1, count)).reversed(), id: \.self) { depth in
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .fill(Color.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.6)))
                    .padding(.horizontal, CGFloat(depth) * Self.edgeInset)
                    .offset(y: CGFloat(depth) * Self.edgeStep)
            }
        }
        .accessibilityHidden(true)
    }

    /// One form at every width, so nothing changes shape as the page narrows: what it is about on
    /// the first line with the way to close it, then what is wrong and the question as a paragraph,
    /// then the way to ask. Beside the text, the buttons left a name a few letters in a narrow page.
    private func card(_ suggestion: Suggestion) -> some View {
        let text = Self.text(suggestion)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent)
                Text(text.subject).font(.headline).lineLimit(1).truncationMode(.middle).help(text.title)
                Spacer(minLength: Spacing.sm)
                dismissMenu(suggestion)
            }
            // Held to a few lines: at its full height, on a page with no scroll of its own, the card
            // pushed the window's content past its top edge.
            (Text(text.problem).fontWeight(.medium) + Text(verbatim: "  ") + Text(text.detail).foregroundStyle(.secondary))
                .font(.callout)
                .lineLimit(3)
                .accessibilityLabel(Text(verbatim: "\(text.title)。\(text.detail)"))
            askButton(suggestion, prompt: text.prompt).controlSize(compact ? .small : .regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Spacing.md)
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

    struct CardText {
        /// The host, node or exit it is about, and what is wrong with it; `title` is both in a sentence.
        let subject: String
        let problem: String
        let title: String
        let detail: String
        let prompt: String
    }

    static func text(_ suggestion: Suggestion) -> CardText {
        switch suggestion.kind {
        case .failing(let host, let count):
            return CardText(subject: host, problem: String(localized: "经常连接失败"),
                     title: String(localized: "\(host) 经常连接失败"),
                     detail: String(localized: "最近 5 分钟失败了 \(count) 次。要不要让它换一个出口？"),
                     prompt: String(localized: "\(host) 最近 5 分钟连接失败了 \(count) 次。帮我看看它现在走哪个出口，并换一个能用的。"))
        case .unmatched(let host, let count):
            return CardText(subject: host, problem: String(localized: "没有匹配任何规则"),
                     title: String(localized: "\(host) 没有匹配任何规则"),
                     detail: String(localized: "最近 10 分钟有 \(count) 次连接落到了最后的 MATCH。要不要为它加一条规则？"),
                     prompt: String(localized: "\(host) 最近一直命中最后的 MATCH 规则。帮我判断它应该直连还是走代理，并加一条规则。"))
        case .slowNode(let group, let node):
            return CardText(subject: node, problem: String(localized: "连续测速超时"),
                     title: String(localized: "“\(node)”连续测速超时"),
                     detail: String(localized: "“\(group)”正在用它。要不要换一个节点？"),
                     prompt: String(localized: "“\(group)”换到延迟最低的节点"))
        case .outage(let exit, let hosts):
            let names = hosts.prefix(3).joined(separator: String(localized: "、"))
            return CardText(subject: exit, problem: String(localized: "\(hosts.count) 个网站经它连接失败"),
                            title: String(localized: "“\(exit)”上有 \(hosts.count) 个网站连接失败"),
                            detail: String(localized: "\(names) 等最近 5 分钟都经这个出口连接失败，多半是出口本身的问题。要不要换一个？"),
                            prompt: String(localized: "经“\(exit)”访问的 \(hosts.joined(separator: ", ")) 最近 5 分钟都连接失败。帮我检查这个出口，并换一个能用的。"))
        }
    }
}
