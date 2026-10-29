import SwiftUI
import VeerCore


struct ToastView: View {
    let toast: Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.veerAccent)
            Text(toast.message).font(.callout)
            if toast.undoable {
                Button(String(localized: "撤销"), action: undo).buttonStyle(.borderless).foregroundStyle(Color.veerAccent)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + Spacing.xxs)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}


/// Thinking strength as a stepped slider (one stop per level the model supports), with the
/// level names under their stops. Click a name to jump to it.
struct ThinkingSlider: View {
    let style: ThinkingStyle
    @Binding var level: ThinkingLevel

    var body: some View {
        let levels = style.levels
        let index = levels.firstIndex(of: style.resolve(level)) ?? 0
        VStack(spacing: Spacing.xxs) {
            Slider(value: Binding(get: { Double(index) }, set: { level = levels[min(max(Int($0.rounded()), 0), levels.count - 1)] }),
                   in: 0...Double(max(levels.count - 1, 1)), step: 1)
                .labelsHidden()
                .tint(.veerAccent)
            GeometryReader { geometry in
                // The knob's centre travels between the track ends, inset by about its radius.
                let inset = Spacing.sm + Spacing.xxs
                let track = geometry.size.width - inset * 2
                ForEach(Array(levels.enumerated()), id: \.element) { offset, item in
                    let label = Text(style.title(of: item))
                        .font(.caption)
                        .fontWeight(offset == index ? .semibold : .regular)
                        .foregroundStyle(offset == index ? Color.primary : Color.secondary)
                        .fixedSize()
                        .onTapGesture { level = item }
                    if offset == 0 {
                        label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else if offset == levels.count - 1 {
                        label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    } else {
                        label.position(x: inset + track * CGFloat(offset) / CGFloat(levels.count - 1), y: geometry.size.height / 2)
                    }
                }
            }
            .frame(height: Spacing.lg)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "深度思考强度"))
        .accessibilityValue(style.title(of: levels[index]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < levels.count { level = levels[index + 1] }
            case .decrement: if index > 0 { level = levels[index - 1] }
            @unknown default: break
            }
        }
    }
}
