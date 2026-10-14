import SwiftUI
import VeerEditor

private struct OpaqueControlsKey: EnvironmentKey {
    nonisolated static let defaultValue = false
}

extension EnvironmentValues {
    var veerOpaqueControls: Bool {
        get { self[OpaqueControlsKey.self] }
        set { self[OpaqueControlsKey.self] = newValue }
    }
}

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case editor, rules, groups, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .editor: "AI 工作台"
        case .rules: "规则稿"
        case .groups: "策略组"
        case .settings: "AI 设置"
        }
    }
    var symbol: String {
        switch self {
        case .editor: "text.bubble"
        case .rules: "doc.text"
        case .groups: "server.rack"
        case .settings: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .editor: "让意图成为规则，由你做最后确认。"
        case .rules: "编辑与导出独立 rules 片段，不覆盖完整配置。"
        case .groups: "登记允许的出口；地区由你声明，并非实测。"
        case .settings: "连接 AI 服务，Key 按 API 地址隔离保存。"
        }
    }
}

enum WorkbenchStyle {
    static let sidebar: CGFloat = 180
    static let radius: CGFloat = 20
    static let inset: CGFloat = 32
    static let contentWidth: CGFloat = 900
    static let utilitySize: CGFloat = 44
    static let fieldRadius: CGFloat = 12
    static let emptyHeight: CGFloat = 180
    static let importButtonSize: CGFloat = 144
    static let importSymbolSize: CGFloat = 56
    static let composerHeight: CGFloat = 72
    static let diffNumberWidth: CGFloat = 36
    static let scrollBottomTolerance: CGFloat = 32
    static let headerTitleWidth: CGFloat = 240
    static let reviewSplitThreshold: CGFloat = 1000
    static let reviewMinimum: CGFloat = 420
    static let reviewMaximum: CGFloat = 540
    static let reviewFraction: CGFloat = 0.44
    static func reviewWidth(in width: CGFloat) -> CGFloat {
        min(reviewMaximum, max(reviewMinimum, width * reviewFraction))
    }
}

struct ImportGlassButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.veerOpaqueControls) private var opaqueControls
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: WorkbenchStyle.importSymbolSize, weight: .light))
                .foregroundStyle(.primary)
                .frame(width: WorkbenchStyle.importButtonSize, height: WorkbenchStyle.importButtonSize)
                .background {
                    if reduceTransparency || opaqueControls {
                        Circle().fill(Color(nsColor: .controlBackgroundColor))
                    } else if #available(macOS 26.0, *) {
                        Circle().fill(.clear).glassEffect(.regular.interactive(), in: .circle)
                    } else { Circle().fill(.regularMaterial) }
                }
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel("导入配置文件或订阅链接")
            .help("导入配置文件或订阅链接（⌘O）")
            .keyboardShortcut("o", modifiers: .command)
    }
}

enum EditorAppearance: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    func toggled(resolvedScheme: ColorScheme) -> Self {
        (scheme ?? resolvedScheme) == .dark ? .light : .dark
    }
}

struct UtilityButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body).imageScale(.medium)
                .foregroundStyle(.primary)
                .frame(width: WorkbenchStyle.utilitySize, height: WorkbenchStyle.utilitySize)
                .modifier(OperationGlass())
        }
        .buttonStyle(.plain)
        .help(title).accessibilityLabel(title)
    }
}

/// Present service-level destinations without concealing individual rule matches.
struct RoutingReviewGroup: Identifiable {
    struct ID: Hashable { let service: String; let target: String?; let kind: String }
    let id: ID
    var changes: [RuleChange]
}

func routingReviewGroups(_ changes: [RuleChange]) -> [RoutingReviewGroup] {
    let netflix = ["netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflxso.net", "nflxext.com"]
    let chatGPT = ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]
    var groups: [RoutingReviewGroup] = []
    for change in changes {
        let match = change.match.lowercased()
        let service = netflix.contains(match) ? "Netflix" : chatGPT.contains(match) ? "ChatGPT" : change.match
        let id = RoutingReviewGroup.ID(service: service, target: change.target, kind: change.kind)
        if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].changes.append(change) }
        else { groups.append(.init(id: id, changes: [change])) }
    }
    return groups
}

/// Content remains solid and readable. Glass belongs to the operation layer.
struct WorkbenchPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EditorLayout.padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.radius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
    }
}

struct OperationGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.veerOpaqueControls) private var opaqueControls
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || opaqueControls {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.radius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: WorkbenchStyle.radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchStyle.radius))
        }
    }
}

struct GlassAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.veerOpaqueControls) private var opaqueControls
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, !opaqueControls {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct GlassUtilityAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.veerOpaqueControls) private var opaqueControls
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, !opaqueControls {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct ToastTrigger: Hashable {
    let generation: Int
    let busy: Bool
    let isError: Bool
}
