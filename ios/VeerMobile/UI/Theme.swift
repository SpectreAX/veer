import SwiftUI
import UIKit

/// Design tokens from the iOS design spec (.airbuild/artifacts/ios-design/design.md §2–4).
/// Names follow VeerUI; colours resolve per trait (light/dark, increased contrast).
extension Color {
    /// Text/glyph green: success, selected node, link buttons, picker values, good delay.
    static let veerAccent = Color(UIColor.veer(light: 0x137538, dark: 0x3DCC80, hcLight: 0x0A5425, hcDark: 0x6BE8A3))
    /// Fill behind a white label: Start, primary buttons, Send.
    static let accentFill = Color(UIColor.veer(light: 0x137538, dark: 0x116B32, hcLight: 0x0A5425, hcDark: 0x0D5C29))
    static let onAccent = Color.white
    static let userBubble = Color(UIColor.veer(light: 0xE0F2E6, dark: 0x294533))
    static let statusWarning = Color(UIColor { @Sendable traits in
        if traits.userInterfaceStyle == .dark { return .systemOrange }
        return UIColor(hex: traits.accessibilityContrast == .high ? 0x944005 : 0xA84B07)
    })
    static let statusFailure = Color(UIColor.veer(light: 0xC62828, dark: 0xFF8484, hcLight: 0xA11A1A, hcDark: 0xFF9E9E))
    static let statusInfo = Color(UIColor.systemBlue)
    static let diffRemoved = Color(UIColor { @Sendable traits in
        UIColor.systemRed.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.16 : 0.11)
    })
    /// Change rows inside the proposal card.
    static let changeRow = Color(UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x2C2C2E) : .systemGroupedBackground
    })
    static let groupedBackground = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let quietFill = Color(UIColor.tertiarySystemFill)
}

// SwiftUI resolves dynamic colours on its async render thread, so the providers must not be
// main-actor isolated (the module default): an isolated provider traps there.
nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func veer(light: UInt32, dark: UInt32, hcLight: UInt32? = nil, hcDark: UInt32? = nil) -> UIColor {
        UIColor { @Sendable traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark { return UIColor(hex: high ? (hcDark ?? dark) : dark) }
            return UIColor(hex: high ? (hcLight ?? light) : light)
        }
    }
}

enum Spacing {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
    static let l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48
}

enum Radius {
    static let hero: CGFloat = 26, proposal: CGFloat = 22, editor: CGFloat = 20
    static let codeSheet: CGFloat = 16, change: CGFloat = 14, code: CGFloat = 12
}

enum Motion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.22)
}

extension Font {
    static let code = Font.footnote.monospaced()
    static let codeSmall = Font.caption.monospaced()
}

/// Status is always icon + text (spec §2).
enum StatusKind {
    case success, warning, failure, info, neutral

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .success: .veerAccent
        case .warning: .statusWarning
        case .failure: .statusFailure
        case .info: .statusInfo
        case .neutral: .secondary
        }
    }
}

struct StatusBadge: View {
    let kind: StatusKind
    let text: String
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.tint)
        }
        .font(font)
        .labelStyle(.titleAndIcon)
    }
}

/// Group type or region tag: caption2 medium in a capsule.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.secondary) // absolute, so it stays legible inside list headers
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(Color.quietFill, in: .capsule)
    }
}

/// Delay with the spec's colour bands; text always shown.
struct DelayText: View {
    /// nil = untested, 0 = timeout.
    let delay: Int?
    var untested: String = "—"

    var body: some View {
        Text(label)
            .font(.code)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var label: String {
        guard let delay else { return untested }
        if delay <= 0 { return String(localized: "超时") }
        return "\(delay) ms"
    }

    private var color: Color {
        guard let delay else { return .secondary }
        if delay <= 0 || delay > 500 { return .statusFailure }
        if delay >= 200 { return .statusWarning }
        return .veerAccent
    }
}

struct PrimaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.onAccent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Spacing.l)
            .background(isEnabled ? Color.accentFill : Color.quietFill, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SecondaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Spacing.l)
            .background(Color.quietFill, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == PrimaryCapsuleStyle {
    static var primaryCapsule: PrimaryCapsuleStyle { .init() }
}

extension ButtonStyle where Self == SecondaryCapsuleStyle {
    static var secondaryCapsule: SecondaryCapsuleStyle { .init() }
}
