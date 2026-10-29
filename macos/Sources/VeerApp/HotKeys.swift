import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What a global shortcut can do. None is bound until the user records one.
enum HotKeyAction: String, CaseIterable, Identifiable, Codable {
    case toggleProxy, switchMode, openWindow, newThread
    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleProxy: String(localized: "开关系统代理")
        case .switchMode: String(localized: "切换出站模式")
        case .openWindow: String(localized: "打开 Veer")
        case .newThread: String(localized: "新建 Agent 对话")
        }
    }
}

/// A key with modifiers, in Carbon's terms so it can be registered as is.
struct HotKey: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// From a key press while recording; nil without ⌘, ⌃ or ⌥, which would steal plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// "⌃⌥P", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(code)] { return name }
        // The character this key types on the current layout, without modifiers.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Whether macOS itself uses this combination (Spotlight, screenshots, input sources…).
    var isSystemShortcut: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return UInt32(code) == keyCode && UInt32(mods) & relevant == modifiers & relevant
        }
    }
}

/// Registers the recorded shortcuts with Carbon, which delivers them whichever app is in front.
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private(set) var bindings: [HotKeyAction: HotKey] = [:]
    /// Why a shortcut could not be registered, by action.
    private(set) var problems: [HotKeyAction: String] = [:]
    @ObservationIgnored var perform: (HotKeyAction) -> Void = { _ in }
    @ObservationIgnored private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "hotKeys"), let saved = try? JSONDecoder().decode([String: HotKey].self, from: data) {
            bindings = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in HotKeyAction(rawValue: key).map { ($0, value) } })
        }
    }

    /// Installs the event handler and registers what was saved.
    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = HotKeyAction.allCases[Int(id.id)]
            DispatchQueue.main.async { HotKeyCenter.shared.perform(action) }
            return noErr
        }, 1, &type, nil, &handler)
        for action in HotKeyAction.allCases { register(action) }
    }

    /// Binds (or with nil unbinds) a shortcut. Returns why it cannot be used, if it cannot.
    @discardableResult func set(_ key: HotKey?, for action: HotKeyAction) -> String? {
        if let key {
            if key.isSystemShortcut { return String(localized: "这个组合已被 macOS 使用。") }
            if let other = bindings.first(where: { $0.value == key && $0.key != action })?.key {
                return String(localized: "这个组合已用于“\(other.title)”。")
            }
        }
        bindings[action] = key
        save()
        register(action)
        return problems[action]
    }

    private func register(_ action: HotKeyAction) {
        if let ref = registered.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        problems[action] = nil
        guard handler != nil, let key = bindings[action] else { return }
        let id = EventHotKeyID(signature: OSType(0x5645_4552), id: UInt32(HotKeyAction.allCases.firstIndex(of: action)!)) // "VEER"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[action] = ref
        } else {
            problems[action] = String(localized: "另一个应用已经占用了这个组合。")
        }
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "hotKeys") }
    }
}

/// Settings' Shortcuts page: one recorder per action.
struct HotKeySettings: View {
    @State private var center = HotKeyCenter.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HotKeyRecorder(action: action, center: center)
                    }
                }
            } footer: {
                Text(String(localized: "点击后按下新的组合，需要包含 ⌘、⌃ 或 ⌥。按 ⎋ 取消，按 ⌫ 清除。在任何应用里都能用。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotKeyRecorder: View {
    let action: HotKeyAction
    let center: HotKeyCenter
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let problem = problem ?? center.problems[action] {
                StatusBadge(kind: .warning, text: problem, compact: true)
            }
            Button(recording ? String(localized: "按下组合…") : center.bindings[action]?.display ?? String(localized: "录制")) {
                recording ? stop() : record()
            }
            .frame(minWidth: 96)
            .neutralControl()
            if center.bindings[action] != nil, !recording {
                Button { problem = center.set(nil, for: action) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(String(localized: "清除"))
                    .accessibilityLabel(String(localized: "清除“\(action.title)”的快捷键"))
            }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                problem = center.set(nil, for: action)
                stop()
            default:
                guard let key = HotKey(event: event) else {
                    problem = String(localized: "需要包含 ⌘、⌃ 或 ⌥。")
                    return nil
                }
                problem = center.set(key, for: action)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
