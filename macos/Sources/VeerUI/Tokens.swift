import SwiftUI
import VeerCore

/// 4-point spacing grid. Views use these instead of literal values.
nonisolated public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

nonisolated public enum Radius {
    /// Keycaps only.
    public static let tiny: CGFloat = 4
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
}

nonisolated public enum Metrics {
    public static let readingWidth: CGFloat = 760
    public static let sidebarWidth: CGFloat = 240
    public static let inspectorWidth: CGFloat = 360
    public static let minWindow = CGSize(width: 860, height: 560)
    public static let defaultWindow = CGSize(width: 1080, height: 720)
    public static let compactBreakpoint: CGFloat = 1100
    /// Below this the page title leaves the profile's name less room beside the toolbar.
    public static let roomyTitleWidth: CGFloat = 960
}

nonisolated public enum Motion {
    public static let quick = Animation.easeOut(duration: 0.15)
    public static let standard = Animation.easeInOut(duration: 0.22)
}

private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

/// One color for each of the appearances people can choose, including Increase Contrast.
private func adaptive(_ name: String, light: NSColor, dark: NSColor, highContrastLight: NSColor, highContrastDark: NSColor) -> Color {
    Color(nsColor: NSColor(name: name) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: dark
        case .accessibilityHighContrastAqua: highContrastLight
        case .accessibilityHighContrastDarkAqua: highContrastDark
        default: light
        }
    })
}

public extension Color {
    /// Veer green: small-area emphasis only (primary actions, selection, written state).
    static let veerAccent = adaptive("VeerAccent", light: rgb(0.075, 0.46, 0.22), dark: rgb(0.24, 0.80, 0.50),
                                     highContrastLight: rgb(0.039, 0.33, 0.145), highContrastDark: rgb(0.42, 0.91, 0.64))
    /// Veer green behind a label or mark, in primary actions, toolbar toggles and checkboxes. Darker than the accent in
    /// dark, where the accent has to read as text on the window and is too light for a white label.
    /// Darker than it needs on paper: Liquid Glass lightens what it is tinted with.
    static let accentFill = adaptive("VeerAccentFill", light: rgb(0.075, 0.46, 0.22), dark: rgb(0.067, 0.42, 0.196),
                                     highContrastLight: rgb(0.039, 0.33, 0.145), highContrastDark: rgb(0.05, 0.36, 0.16))
    /// A label or glyph on `accentFill`.
    static let onAccent = Color.white

    /// Behind the selected row of a sidebar or list: the system's own, which follows the color the
    /// person chose and stays dark enough for a white label, as the plain accent color doesn't.
    static let selectionFill = Color(nsColor: .selectedContentBackgroundColor)

    /// User message bubble: a light wash of the accent with normal text, so the solid accent is
    /// left for primary actions.
    static let userBubble = Color(nsColor: NSColor(name: "VeerBubble") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.27, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.95, blue: 0.90, alpha: 1)
    })
    static let statusSuccess = Color.veerAccent
    /// Not the system's: these are small text, such as a node's delay, on white and on a selected
    /// tile's wash of the accent, where the system's are too faint.
    static let statusWarning = adaptive("VeerWarning", light: rgb(0.659, 0.294, 0.027), dark: .systemOrange,
                                        highContrastLight: rgb(0.58, 0.25, 0.02), highContrastDark: .systemOrange)
    static let statusFailure = adaptive("VeerFailure", light: rgb(0.776, 0.157, 0.157), dark: rgb(1, 0.518, 0.518),
                                        highContrastLight: rgb(0.63, 0.1, 0.1), highContrastDark: rgb(1, 0.62, 0.62))
    static let statusInfo = Color(nsColor: .systemBlue)

    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
    static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
    static let separatorLine = Color(nsColor: .separatorColor)
    static let codeBackground = Color(nsColor: .textBackgroundColor)
    static let diffAdded = Color.veerAccent.opacity(0.13)
    /// Quiet fill that sets secondary text (model reasoning) apart from the white page.
    static let subtleFill = Color.primary.opacity(0.05)
    static let diffRemoved = Color(nsColor: .systemRed).opacity(0.11)
}

nonisolated /// Categorical chart colors in fixed order (never cycled), validated for adjacent-pair CVD
/// separation on light (#ffffff) and dark (#1e1e1e) surfaces. Light slots 3–5 sit below 3:1
/// contrast, so every chart shows a legend with exact counts. A 7th category folds into 其他.
public enum ChartPalette {
    public static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70),
        (0xeda100, 0xc98500), (0xe87ba4, 0xd55181), (0x008300, 0x008300),
    ]
    public static let maxSlots = 6

    public static func color(_ index: Int) -> Color {
        let slot = slots[index % slots.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? slot.dark : slot.light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    /// Neutral for the folded "其他" bucket: not a categorical hue.
    public static let other = Color(nsColor: .systemGray)
}

public enum Typography {
    public static let code = Font.system(.callout, design: .monospaced)
    public static let codeSmall = Font.system(.caption, design: .monospaced)
}

/// Semantic status, always rendered as icon + text.
public enum StatusKind {
    case success, warning, failure, info, neutral

    public var color: Color {
        switch self {
        case .success: .statusSuccess
        case .warning: .statusWarning
        case .failure: .statusFailure
        case .info: .statusInfo
        case .neutral: .secondary
        }
    }

    public var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    public init(_ validation: ValidationResult.Status) {
        switch validation {
        case .passed: self = .success
        case .unavailable: self = .warning
        case .failed: self = .failure
        }
    }

    public init(_ verification: RuleSetVerification) {
        switch verification {
        case .verified, .reused: self = .success
        case .unverified: self = .warning
        case .missing: self = .failure
        }
    }
}

public extension RuleSetVerification {
    var label: String {
        switch self {
        case .verified: String(localized: "地址已验证")
        case .unverified: String(localized: "地址未验证（网络不可达）")
        case .missing: String(localized: "地址不存在")
        case .reused: String(localized: "复用已有规则集")
        }
    }
}

public extension Target.Kind {
    var label: String {
        switch self {
        case .group: String(localized: "策略组")
        case .node: String(localized: "节点")
        case .builtin: String(localized: "内置")
        }
    }
}
