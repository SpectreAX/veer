import SwiftUI
import VeerCore

/// Composer popover for who reads the instruction: AI (the service's model and thinking strength)
/// or local parsing. One control instead of separate parse-mode and model buttons.
struct ModelPopover: View {
    @Environment(AgentStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        @Bindable var store = store
        let settings = store.settings
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "谁来理解指令")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.sm)
                ChoiceRow(number: 1, symbol: "sparkles", title: "AI · \(settings.provider.title)",
                          detail: String(localized: "理解复杂说法，可以追问和联网搜索；只发送匿名结构。"),
                          selected: store.useAI) { store.useAI = true }
                ChoiceRow(number: 2, symbol: "text.magnifyingglass", title: String(localized: "本地解析"),
                          detail: String(localized: "在本机识别常见服务、域名、IP 和地区，不发送任何内容。"),
                          selected: !store.useAI) { store.useAI = false }
            }
            .padding(.horizontal, -Spacing.sm)

            if store.useAI && !store.aiConfigured {
                HStack {
                    StatusBadge(kind: .warning, text: String(localized: "还没有 \(settings.provider.title) 的 API Key，暂时会改用本地解析"), compact: true)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "设置…"), action: openSettings).buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
            }

            if store.useAI {
                Divider()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "模型 · \(settings.provider.title)")).font(.caption).foregroundStyle(.secondary)
                    let models = settings.models(includingFetched: true)
                    ScrollView {
                        VStack(spacing: Spacing.xxs) {
                            ForEach(models, id: \.self) { model in
                                ModelRow(model: model, selected: model == settings.model) {
                                    store.settings.select(model: model)
                                    store.useAI = true
                                }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: models.count > 7 ? 220 : nil)
                    .fixedSize(horizontal: false, vertical: models.count <= 7)
                }

                Divider()

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Label(String(localized: "深度思考"), systemImage: "brain").font(.callout)
                        Spacer()
                        Text(settings.thinkingStyle.adjustable ? settings.thinkingStyle.title(of: settings.effectiveLevel)
                             : settings.thinks ? String(localized: "始终开启") : String(localized: "不支持"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if settings.thinkingStyle.adjustable {
                        ThinkingSlider(style: settings.thinkingStyle,
                                       level: Binding(get: { store.settings.effectiveLevel }, set: { store.settings.thinkingLevel = $0 }))
                        Text(String(localized: "强度越高，理解复杂指令越好，但更慢、费用更高。")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(settings.thinks ? String(localized: "推理模型，总是先思考再回答。") : String(localized: "此模型不能深度思考，可换用支持的模型。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                Button(String(localized: "AI 设置…"), action: openSettings).buttonStyle(.link).foregroundStyle(Color.veerAccent)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 340)
    }
}

/// One selectable model in the popover list.
private struct ModelRow: View {
    let model: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Text(model).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Spacing.sm)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.veerAccent).fontWeight(.semibold) }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(selected ? Color.veerAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
