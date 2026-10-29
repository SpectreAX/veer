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
    public static let minWindow = CGSize(width: 960, height: 640)
    public static let defaultWindow = CGSize(width: 1320, height: 860)
    public static let compactBreakpoint: CGFloat = 1100
}

nonisolated public enum Motion {
    public static let quick = Animation.easeOut(duration: 0.15)
    public static let standard = Animation.easeInOut(duration: 0.22)
}

public extension Color {
    /// Veer green: small-area emphasis only (primary actions, selection, written state).
    static let veerAccent = Color(nsColor: NSColor(name: "VeerAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.80, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.62, blue: 0.33, alpha: 1)
    })
    /// User message bubble: a light wash of the accent with normal text, so the solid accent is
    /// left for primary actions.
    static let userBubble = Color(nsColor: NSColor(name: "VeerBubble") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.27, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.95, blue: 0.90, alpha: 1)
    })
    static let statusSuccess = Color.veerAccent
    static let statusWarning = Color(nsColor: .systemOrange)
    static let statusFailure = Color(nsColor: .systemRed)
    static let statusInfo = Color(nsColor: .systemBlue)

    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
    static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
    static let separatorLine = Color(nsColor: .separatorColor)
    static let codeBackground = Color(nsColor: .textBackgroundColor)
    static let diffAdded = Color.veerAccent.opacity(0.13)
    /// Selected segment of a segmented control: a neutral gray (white text stays above 4.5:1), so
    /// the accent is not spent on navigation.
    static let selectionNeutral = Color(nsColor: NSColor(name: "VeerSelectionNeutral") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.40, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.39, green: 0.39, blue: 0.40, alpha: 1)
    })
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
