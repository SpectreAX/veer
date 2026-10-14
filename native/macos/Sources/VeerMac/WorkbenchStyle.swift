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
nonisolated struct RoutingReviewGroup: Identifiable {
    struct ID: Hashable, Codable { let service: String; let target: String?; let kind: String }
    let id: ID
    var changes: [RuleChange]
}

nonisolated let serviceCatalog: [(name: String, domains: [String])] = [
    ("Netflix", ["netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflxso.net", "nflxext.com"]),
    ("ChatGPT", ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]),
    ("YouTube", ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "youtube-nocookie.com"]),
    ("Telegram", ["telegram.org", "t.me", "telegram.me"]),
]

/// The service card a single rule change belongs to.
nonisolated func routingGroupID(_ change: RuleChange) -> RoutingReviewGroup.ID {
    let match = change.match.lowercased()
    let service = serviceCatalog.first { $0.domains.contains(match) }?.name ?? change.match
    return RoutingReviewGroup.ID(service: service, target: change.target, kind: change.kind)
}

nonisolated func routingReviewGroups(_ changes: [RuleChange]) -> [RoutingReviewGroup] {
    var groups: [RoutingReviewGroup] = []
    for change in changes {
        let id = routingGroupID(change)
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

/// One validation result, distinguished by symbol and wording as well as color.
struct ValidationLabel: View {
    let validation: Validation
    var body: some View {
        Label {
            Text(validation.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption).foregroundStyle(color)
        .accessibilityLabel("\(title)：\(validation.message)")
    }
    private var title: String {
        switch validation.status { case "passed": "校验通过"; case "failed": "校验失败"; default: "未经内核校验" }
    }
    private var symbol: String {
        switch validation.status { case "passed": "checkmark.shield"; case "failed": "xmark.octagon"; default: "exclamationmark.triangle" }
    }
    private var color: Color {
        switch validation.status { case "passed": .green; case "failed": .red; default: .orange }
    }
}

struct LineChangeBadge: View {
    let count: LineChangeCount
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(count.added)").foregroundStyle(.green)
            Text("−\(count.removed)").foregroundStyle(.red)
        }.font(.caption.monospaced())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("新增 \(count.added) 行，删除 \(count.removed) 行")
    }
}

/// Bundled service status above the conversation. Hidden while ready or never started.
struct ServiceBanner: View {
    let state: ServiceState
    let restart: () -> Void
    var body: some View {
        switch state {
        case .starting:
            HStack(spacing: EditorLayout.small) {
                ProgressView().controlSize(.small)
                Text("正在启动内置编辑服务…")
            }.font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        case .unavailable(let message):
            HStack(alignment: .top, spacing: EditorLayout.small) {
                Image(systemName: "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 2) {
                    Text("内置编辑服务不可用。草稿仍在内存中，未丢失。")
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: EditorLayout.small)
                Button("重新启动服务", action: restart).modifier(GlassUtilityAction())
            }.font(.caption).foregroundStyle(.red)
        case .idle, .ready:
            EmptyView()
        }
    }
}

extension WorkbenchStyle {
    static let inspectorMinimum: CGFloat = 360
    static let conversationMinimum: CGFloat = 420
    static let inspectorDefault: CGFloat = 440
    /// Keep the stored width usable for the current window: never squeeze the conversation below its minimum.
    static func inspectorWidth(_ stored: Double, in available: CGFloat) -> CGFloat {
        let maximum = max(inspectorMinimum, available - conversationMinimum - EditorLayout.section)
        return min(max(CGFloat(stored), inspectorMinimum), maximum)
    }
}

/// Drag to resize the inspector; double-click resets; arrow keys adjust when focused.
struct SplitHandle: View {
    @Binding var width: Double
    let current: CGFloat
    let available: CGFloat
    @GestureState private var origin: CGFloat?
    var body: some View {
        Capsule()
            .fill(origin != nil ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: 4, height: 40)
            .frame(minWidth: EditorLayout.section, maxWidth: EditorLayout.section, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 4)
                .updating($origin) { _, state, _ in if state == nil { state = current } }
                .onChanged { value in
                    // A 4pt minimum distance keeps clicks from resizing.
                    let base = origin ?? current
                    width = Double(WorkbenchStyle.inspectorWidth(Double(base - value.translation.width), in: available))
                })
            .onTapGesture(count: 2) { width = Double(WorkbenchStyle.inspectorDefault) }
            .focusable()
            .onKeyPress(.leftArrow) { width = Double(WorkbenchStyle.inspectorWidth(Double(current + 24), in: available)); return .handled }
            .onKeyPress(.rightArrow) { width = Double(WorkbenchStyle.inspectorWidth(Double(current - 24), in: available)); return .handled }
            .accessibilityElement()
            .accessibilityLabel("调整检查器宽度")
            .accessibilityValue("\(Int(current)) 点")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 24 : -24
                width = Double(WorkbenchStyle.inspectorWidth(Double(current + step), in: available))
            }
    }
}

struct SessionRow: View {
    let record: StoredSession
    let active: Bool
    let unexported: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if unexported { Circle().fill(.orange).frame(width: 6, height: 6).accessibilityLabel("有未导出的修改") }
                Text(record.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(record.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 2)
            .help(record.name)
    }
}
