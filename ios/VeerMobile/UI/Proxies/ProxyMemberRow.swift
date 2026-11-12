import SwiftUI

struct ProxyMemberRow: View {
    @Environment(ProxyStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var markSize = 22
    let member: ProxyStore.Group.Member
    let selected: Bool
    let selectable: Bool
    let testing: Bool
    let select: () -> Void

    var body: some View {
        Group {
            if selectable {
                Button(action: select) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(testing ? String(localized: "测速") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("node-\(member.name)")
    }

    private var accessibilityDescription: String {
        let delay = ProxyPresentation.spokenDelay(member.delay)
        return selected ? String(localized: "\(displayName)，延迟 \(delay)，正在使用")
            : String(localized: "\(displayName)，延迟 \(delay)")
    }

    private var displayName: String {
        ProxyPresentation.nodeName(member.name, isNode: member.isNode, store: store)
    }

    private var content: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: markSize))
                .foregroundStyle(selected ? Color.veerAccent : Color(UIColor.tertiaryLabel))
                .frame(width: markSize)
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    title
                    delay
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                title.frame(maxWidth: .infinity, alignment: .leading)
                delay
            }
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(displayName)
            .font(.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var delay: some View {
        if testing {
            ProgressView().controlSize(.small).accessibilityLabel("测速")
        } else {
            DelayText(delay: member.delay, untested: member.isNode ? String(localized: "未测速") : "—")
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var symbol: String {
        if selected { return "checkmark.circle.fill" }
        return member.isGroup ? "square.stack.3d.up" : "circle"
    }
}
