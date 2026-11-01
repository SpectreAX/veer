import AppKit
import SwiftUI
import VeerCore

/// Icon + text status label. Color is never the only cue.
public struct StatusBadge: View {
    public init(kind: StatusKind, text: String, compact: Bool = false) {
        self.kind = kind
        self.text = text
        self.compact = compact
    }

    public let kind: StatusKind
    public let text: String
    public var compact = false

    public var body: some View {
        Label {
            Text(text).foregroundStyle(compact ? Color.secondary : Color.primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(compact ? .caption : .callout)
        .accessibilityElement(children: .combine)
    }
}

/// Small rounded tag, e.g. "策略组", "新增".
public struct Tag: View {
    public init(text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public let text: String
    public var tint: Color = .secondary

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            // One line whatever the room: broken up, it stops reading as a label.
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs + Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Selectable suggestion pill. Enabled pills carry a faint accent edge and react to the pointer,
/// so they read as clickable; disabled ones (for example in older turns) fade out.
public struct Chip: View {
    public init(text: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.text = text
        self.symbol = symbol
        self.action = action
    }

    public let text: String
    public var symbol: String?
    public let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(isEnabled ? Color.veerAccent : Color.secondary) }
                Text(text).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(hovering && isEnabled ? Color.veerAccent.opacity(0.12) : Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(isEnabled ? Color.veerAccent.opacity(0.35) : Color.separatorLine))
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// Icon pill for the composer's menu buttons: a neutral (or tinted) wash that deepens on hover and
/// press, like `ToggleChip` beside it.
public struct PillButtonStyle: ButtonStyle {
    public init(tint: Color? = nil) { self.tint = tint }

    public var tint: Color?

    public func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color?
        @State private var hovering = false

        var body: some View {
            let base = tint == nil ? 0.06 : 0.14
            configuration.label
                .font(.callout)
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, Spacing.sm + Spacing.xxs)
                .padding(.vertical, Spacing.xs)
                .background((tint ?? .primary).opacity(configuration.isPressed ? base + 0.08 : hovering ? base + 0.04 : base), in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// On / off pill for a composer option. Off it matches the neutral mode pill beside it; on it takes
/// an accent wash, edge and text, so the state reads from more than color alone (also announced as
/// selected).
public struct ToggleChip: View {
    public init(title: String, symbol: String, isOn: Binding<Bool>, compact: Bool = false) {
        self.title = title
        self.symbol = symbol
        _isOn = isOn
        self.compact = compact
    }

    public let title: String
    public let symbol: String
    @Binding public var isOn: Bool
    /// Icon only, for narrow rows; the title stays as the accessibility label.
    public var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.adaptive(compact))
                .font(.callout)
                .foregroundStyle(isOn && isEnabled ? Color.veerAccent : isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, Spacing.sm + Spacing.xxs)
                .padding(.vertical, Spacing.xs)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn && isEnabled ? Color.veerAccent.opacity(0.4) : .clear))
                .opacity(isEnabled ? 1 : 0.6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: isOn)
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var background: Color {
        guard isEnabled else { return Color.primary.opacity(0.06) }
        if isOn { return Color.veerAccent.opacity(hovering ? 0.2 : 0.14) }
        return Color.primary.opacity(hovering ? 0.1 : 0.06)
    }
}

public struct AdaptiveLabelStyle: LabelStyle {
    public init(iconOnly: Bool) { self.iconOnly = iconOnly }

    public let iconOnly: Bool
    public func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { Label(configuration) }
    }
}

public extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(_ iconOnly: Bool) -> AdaptiveLabelStyle { AdaptiveLabelStyle(iconOnly: iconOnly) }
}

/// Centered empty / error / informational state with an optional action.
public struct StateView: View {
    public init(symbol: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public let symbol: String
    public let title: String
    public var message: String?
    public var actionTitle: String?
    public var action: (() -> Void)?

    public var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).secondaryAction()
            }
        }
        .frame(maxWidth: 320)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Exit name with its region and kind, used in lists and completions.
public struct ExitLabel: View {
    public init(name: String, region: Region?, kind: Target.Kind? = nil) {
        self.name = name
        self.region = region
        self.kind = kind
    }

    public let name: String
    public let region: Region?
    public var kind: Target.Kind?

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(name).lineLimit(1).truncationMode(.middle).help(name)
            if let region { Text(region == .unknown ? String(localized: "未指定地区") : region.displayName).font(.caption).foregroundStyle(.secondary) }
            if let kind { Tag(text: kind.label) }
        }
    }
}

/// Primary glass action. Uses native Liquid Glass on macOS 26, where the system falls back to an
/// opaque treatment when Reduce Transparency is on; older systems get the bordered prominent style.
public struct PrimaryActionStyle: ViewModifier {
    public init(size: ControlSize = .large) { self.size = size }

    public let size: ControlSize

    public func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.borderedProminent)
            }
        }
        .tint(.accentFill)
        .controlSize(size)
    }
}

/// A selected row in a sidebar or list, the same whether the list or something else has the focus. The
/// system dims it when the focus leaves, and a page that moves the focus to its own field makes that
/// flash between the two. Only a window in the background still looks dimmed, as it should.
private struct SelectionHighlight: ViewModifier {
    let isSelected: Bool
    @Environment(\.controlActiveState) private var activeState

    private var isShown: Bool { isSelected && activeState != .inactive }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isShown ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
            .listRowBackground(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(isShown ? Color.selectionFill : .clear)
                    .padding(.horizontal, Spacing.sm + Spacing.xxs),
            )
    }
}

public extension View {
    func selectionHighlight(_ isSelected: Bool) -> some View { modifier(SelectionHighlight(isSelected: isSelected)) }
}

/// Secondary action beside content (Update, Test, Use): clear Liquid Glass on macOS 26, the
/// bordered style before it. Uncolored, so the accent stays on the one primary action.
public struct SecondaryActionStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
        .tint(nil)
    }
}

public extension View {
    func primaryAction(_ size: ControlSize = .large) -> some View { modifier(PrimaryActionStyle(size: size)) }
    func secondaryAction() -> some View { modifier(SecondaryActionStyle()) }

    /// A panel that floats above the window, such as onboarding: Liquid Glass on macOS 26, the
    /// regular material before it. Not for ordinary content, which stays on solid `panel()`.
    func floatingPanel(padding: CGFloat = Spacing.xl) -> some View {
        self.padding(padding).glassSurface(in: RoundedRectangle(cornerRadius: Radius.large * 1.5, style: .continuous))
    }

    /// Liquid Glass in `shape` on macOS 26; the regular material with a hairline edge before it.
    @ViewBuilder func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color.separatorLine.opacity(0.6)))
        }
    }

    /// Solid content panel: no glass on content.
    func panel(padding: CGFloat = Spacing.lg) -> some View {
        self.padding(padding)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.6)))
    }
}

/// Neighbouring glass shapes: `GlassEffectContainer` on macOS 26, its content before it. Shapes
/// closer than `spacing` blend.
public struct GlassGroup<Content: View>: View {
    public init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    let spacing: CGFloat
    let content: Content

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

public extension View {
    /// The system's own look for selection controls and secondary buttons, rather than Veer's
    /// green, which is kept for the one primary action of a view so it stays easy to find.
    func neutralControl() -> some View { tint(nil) }

    /// A checkbox whose white check reads in dark too, as it doesn't on the accent everything else
    /// inherits. Not by changing that tint: the text caret takes it, and would be dark green on dark.
    func accentCheckbox() -> some View { toggleStyle(.checkbox).tint(.accentFill) }
}

/// The standard SwiftUI segmented picker, with the selected segment in the system's own color (the
/// accent the person chose) rather than Veer's green, as in any other Mac app.
public struct SegmentedControl<Value: Hashable>: View {
    public init(label: String, selection: Binding<Value>, options: [Option]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public struct Option {
        public init(value: Value, title: String, symbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }

        public let value: Value
        public let title: String
        public var symbol: String?
    }

    public let label: String
    @Binding public var selection: Value
    public let options: [Option]

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Group {
                    if let symbol = option.symbol {
                        Image(systemName: symbol).accessibilityLabel(option.title).help(option.title)
                    } else {
                        Text(option.title)
                    }
                }
                .tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .neutralControl()
    }
}

/// A switch that stands alone in the window's top row, on glass that the toolbar gives it. Custom because the system's segmented picker draws its own track there, and only takes on glass
/// inside a real toolbar, which Veer leaves empty (see DESIGN_SPEC). Selection is a shape, not a
/// color, and buttons keep it reachable from the keyboard and VoiceOver.
public struct GlassSwitch<Value: Hashable>: View {
    public init(label: String, selection: Binding<Value>, options: [Option]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public struct Option {
        public init(value: Value, title: String, symbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }

        public let value: Value
        public let title: String
        public let symbol: String?
    }

    public let label: String
    @Binding public var selection: Value
    public let options: [Option]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    if let symbol = option.symbol {
                        Label(option.title, systemImage: symbol).labelStyle(.iconOnly).font(.title3)
                    } else {
                        Text(option.title).font(.callout.weight(.medium)).padding(.horizontal, Spacing.md)
                    }
                }
                .buttonStyle(GlassSwitchButtonStyle())
                .background {
                    if isSelected {
                        Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                // A word says it already; a symbol needs the tooltip.
                .help(option.symbol == nil ? "" : option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : Motion.standard, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A segment of `GlassSwitch`: a soft highlight on hover and press, under the selection's own.
private struct GlassSwitchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(minWidth: 44, minHeight: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 && isEnabled }
            .animation(Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: hovering)
    }
}

/// A key or key combination shown as a keycap, e.g. "⇧↩" or "1": one surface step up with a
/// hairline edge, no gradient or shadow. Decorative for VoiceOver; the action's label says it.
public struct KeyCap: View {
    public init(keys: String) { self.keys = keys }

    public let keys: String

    public var body: some View {
        Text(verbatim: keys)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs / 2)
            .frame(minWidth: Spacing.lg)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.tiny))
            .overlay(RoundedRectangle(cornerRadius: Radius.tiny).strokeBorder(Color.separatorLine))
            .accessibilityHidden(true)
    }
}

/// Keycap followed by what it does, for hint rows.
public struct ShortcutHint: View {
    public init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }

    public let keys: String
    public let label: String

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            KeyCap(keys: keys)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys) \(label)")
    }
}

/// A menu choice like Claude's mode menu: icon, title, what it does, a check when current, and
/// its number key (pressed while the menu is open).
public struct ChoiceRow: View {
    public init(number: Int, symbol: String, title: String, detail: String, selected: Bool, tint: Color? = nil, action: @escaping () -> Void) {
        self.number = number
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.selected = selected
        self.tint = tint
        self.action = action
    }

    public let number: Int
    public let symbol: String
    public let title: String
    public let detail: String
    public let selected: Bool
    public var tint: Color? = nil
    public let action: () -> Void
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: symbol).frame(width: Spacing.lg).foregroundStyle(tint ?? .secondary)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.body).foregroundStyle(tint ?? .primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.veerAccent).fontWeight(.semibold) }
                KeyCap(keys: "\(number)")
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
