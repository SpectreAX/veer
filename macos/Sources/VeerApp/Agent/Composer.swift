import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeerCore

struct CompletionItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let insertion: String
    var tag: String?
}

/// Bottom composer: auto-growing input, @ exit and / command completion, mode switch, send/stop.
struct ComposerView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var height: CGFloat = 22
    @State private var query: (trigger: Character, text: String)?
    @State private var highlighted = 0
    @State private var replaceRequest: CompletionItem?
    /// An input method is composing (pinyin shown as marked text) but nothing is committed yet.
    @State private var composing = false
    @State private var completionHeight: CGFloat = 0
    @State private var droppingFiles = false

    private var canSend: Bool {
        guard store.loadingAttachments == 0 else { return false }
        return !store.pendingAttachments.isEmpty || !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var completions: [CompletionItem] {
        guard let query else { return [] }
        let needle = query.text.lowercased()
        if query.trigger == "/" {
            let commands = [
                CompletionItem(id: "/undo", title: "/undo", detail: String(localized: "撤销最近应用的修改"), insertion: "/undo"),
                CompletionItem(id: "/redo", title: "/redo", detail: String(localized: "重新应用撤销的修改"), insertion: "/redo"),
            ]
            return commands.filter { needle.isEmpty || $0.title.contains(needle) }
        }
        let regions = store.regions
        return (store.draft?.targets ?? [])
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .prefix(8)
            .map { target in
                let region = target.kind == .builtin ? (target.name == "DIRECT" ? String(localized: "直连") : String(localized: "拦截")) : (regions[target.name] ?? .unknown).displayName
                return CompletionItem(id: target.id, title: target.name, detail: region, insertion: "@\(target.name) ", tag: target.kind.label)
            }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !store.pendingAttachments.isEmpty || store.loadingAttachments > 0 || store.attachmentProblem != nil { attachments }
                ZStack(alignment: .topLeading) {
                    if store.composerText.isEmpty && !composing {
                        Text(String(localized: "描述分流，例如“Netflix 走日本，ChatGPT 走美国”"))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, Spacing.xs + 1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $store.composerText, composing: $composing, height: $height, query: $query,
                        focusToken: store.composerFocusToken, replaceRequest: $replaceRequest,
                        hasCompletions: !completions.isEmpty,
                        onMove: { delta in
                            guard !completions.isEmpty else { return }
                            highlighted = (highlighted + delta + completions.count) % completions.count
                        },
                        onPick: { pick(completions[min(highlighted, completions.count - 1)]) },
                        onSubmit: { store.send() },
                        onPasteFiles: { store.attach($0) },
                        onPasteImage: { store.attach(imageData: $0) },
                    )
                    .frame(height: height)
                    .disabled(store.isRunning)
                    .accessibilityLabel(String(localized: "分流指令"))
                }
                HStack(spacing: Spacing.sm) {
                    // Icons only; names and states are in each button's tooltip and menu. The hint goes
                    // first when the row is narrow.
                    ViewThatFits(in: .horizontal) {
                        options(hint: true)
                        options(hint: false)
                    }
                    if store.isRunning {
                        Button { store.cancel() } label: { Image(systemName: "stop.fill") }
                            .help(String(localized: "停止生成（⌘.）")).accessibilityLabel(String(localized: "停止生成"))
                            .secondaryAction().controlSize(.large)
                            .buttonBorderShape(.circle)
                    } else {
                        Button { store.send() } label: { Image(systemName: "arrow.up") .fontWeight(.semibold) }
                            .help(String(localized: "发送（↩）")).accessibilityLabel(String(localized: "发送"))
                            .primaryAction()
                            .buttonBorderShape(.circle)
                            .disabled(!canSend)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            // One glass shape for the field, its controls and its padding, applied after the padding so
            // it covers all of them. The conversation scrolls on behind it and the glass blurs it, on the
            // Agent page and in the panel alike. The system adapts the glass to the window's state,
            // the appearance, and the transparency and contrast settings; nothing of Veer's is drawn
            // over it. Before macOS 26, the regular material, which blurs too.
            .glassSurface(in: RoundedRectangle(cornerRadius: Radius.large + Spacing.xs, style: .continuous))
            .overlay {
                if droppingFiles {
                    RoundedRectangle(cornerRadius: Radius.large + Spacing.xs, style: .continuous)
                        .strokeBorder(Color.veerAccent, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard store.effectiveUseAI, !files.isEmpty else { return false }
                store.attach(files)
                return true
            } isTargeted: { droppingFiles = $0 && store.effectiveUseAI }
            .overlay(alignment: .topLeading) {
                if !completions.isEmpty {
                    // Lifted by its own measured height so it floats above the composer; an
                    // alignment guide alone left it drawn downward over the controls.
                    CompletionList(items: completions, highlighted: min(highlighted, completions.count - 1), pick: pick)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { completionHeight = $0 }
                        .offset(y: -completionHeight - Spacing.sm)
                        .opacity(completionHeight > 0 ? 1 : 0)
                }
            }
            // As many hints as the width allows: the side panel fits two.
            ViewThatFits(in: .horizontal) {
                hints(4)
                hints(2)
            }
        }
        .onChange(of: query?.text) { highlighted = 0 }
        .fileImporter(isPresented: $store.choosingAttachments, allowedContentTypes: AttachmentReader.offeredTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.attach(urls) }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !store.pendingAttachments.isEmpty || store.loadingAttachments > 0 {
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(store.pendingAttachments) { attachment in
                        AttachmentChip(info: attachment.info, thumbnail: attachment.image?.data) { store.removeAttachment(attachment.id) }
                    }
                    if store.loadingAttachments > 0 {
                        ProgressView().controlSize(.small).accessibilityLabel(String(localized: "正在读取"))
                    }
                }
            }
            if let problem = store.attachmentProblem { StatusBadge(kind: .failure, text: problem, compact: true).lineLimit(3) }
            if !store.pendingAttachments.isEmpty {
                // Not a fixed height: measured at the window's narrowest, a long line grows taller than
                // the window, and the window's content is pushed out past its top.
                Text(attachmentNote).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private var attachmentNote: String {
        var note = store.pendingAttachments.contains { $0.image != nil }
            ? String(localized: "文件里的密钥和链接发送前会隐藏；图片会原样发给 AI 服务。")
            : String(localized: "文件里的密钥和链接发送前会隐藏。这条指令的修改都需要你确认。")
        if store.pendingAttachments.contains(where: \.info.truncated) { note += String(localized: "有的文件太长，只会发送开头。") }
        return note
    }

    private func hints(_ count: Int) -> some View {
        HStack(spacing: Spacing.md) {
            // Return to send is what anyone tries first; @ and / are what nobody would guess.
            if count > 2 {
                ShortcutHint(keys: "↩", label: String(localized: "发送"))
                ShortcutHint(keys: "⇧↩", label: String(localized: "换行"))
            }
            ShortcutHint(keys: "@", label: String(localized: "选择出口"))
            ShortcutHint(keys: "/", label: String(localized: "命令"))
        }
    }

    private func options(hint: Bool) -> some View {
        @Bindable var store = store
        return HStack(spacing: Spacing.sm) {
            ExecutionModePicker()
            modelMenu
            Button { store.choosingAttachments = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(PillButtonStyle())
                .fixedSize()
                .disabled(!store.effectiveUseAI)
                .help(store.effectiveUseAI ? String(localized: "添加图片或文件，也可以拖到这里或粘贴")
                                           : String(localized: "图片和文件只在 AI 解析时可用"))
                .accessibilityLabel(String(localized: "添加图片或文件"))
            ToggleChip(title: String(localized: "联网搜索"), symbol: "globe", isOn: $store.searchSettings.enabled, compact: true)
                .disabled(!store.effectiveUseAI)
                .help(store.effectiveUseAI
                      ? (store.searchSettings.enabled ? String(localized: "AI 可以联网搜索规则集和官方域名（点按关闭）") : String(localized: "开启后 AI 可以联网搜索规则集和官方域名"))
                      : String(localized: "联网搜索只在 AI 解析时可用"))
            Spacer(minLength: 0)
            if hint {
                Text(String(localized: "请勿粘贴密钥或订阅链接")).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    /// Who reads the instruction: AI (model, thinking strength) or local parsing.
    private var modelMenu: some View {
        @Bindable var store = store
        let settings = store.settings
        let ai = store.useAI
        return Button { store.showingModelPopover.toggle() } label: {
            Image(systemName: !ai ? "text.magnifyingglass" : settings.thinks ? "brain" : "sparkles")
                .overlay(alignment: .topTrailing) {
                    if ai && !store.aiConfigured {
                        Circle().fill(Color.statusWarning).frame(width: Spacing.sm - Spacing.xxs, height: Spacing.sm - Spacing.xxs)
                            .offset(x: Spacing.xs, y: -Spacing.xxs)
                    }
                }
        }
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .help(!ai ? String(localized: "本地解析。点按选择 AI 或本地解析")
              : store.aiConfigured ? String(localized: "AI · \(settings.modelLabel)。点按选择模型、思考强度或改用本地解析")
              : String(localized: "AI 解析：还没有 API Key，会改用本地解析"))
        .accessibilityLabel(ai ? String(localized: "解析：AI，\(settings.modelLabel)") : String(localized: "解析：本地"))
        .popover(isPresented: $store.showingModelPopover, arrowEdge: .top) {
            ModelPopover {
                store.showingModelPopover = false
                openSettings()
            }
            .environment(store)
        }
    }

    private func pick(_ item: CompletionItem) {
        replaceRequest = item
        query = nil
    }
}

struct CompletionList: View {
    let items: [CompletionItem]
    let highlighted: Int
    let pick: (CompletionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { pick(item) } label: {
                    HStack(spacing: Spacing.sm) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.md)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        if let tag = item.tag { Tag(text: tag) }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs + Spacing.xxs)
                    .background(index == highlighted ? Color.veerAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.xs)
        .frame(width: 340)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.separatorLine))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// A file or image going with an instruction: in the composer with a way to remove it, in the
/// conversation without one.
struct AttachmentChip: View {
    let info: AttachmentInfo
    var thumbnail: Data?
    var remove: (() -> Void)?

    /// The smallest target the HIG gives a macOS control.
    private static let rowHeight: CGFloat = 20

    private var note: String {
        var parts = [info.name]
        if info.redacted { parts.append(String(localized: "已隐藏密钥和链接")) }
        if info.truncated { parts.append(remove == nil ? String(localized: "内容太长，只发送了开头") : String(localized: "内容太长，只会发送开头")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let thumbnail, let image = NSImage(data: thumbnail) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: Self.rowHeight, height: Self.rowHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: info.kind == .image ? "photo" : "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(verbatim: info.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if info.redacted { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
            if info.truncated { Image(systemName: "scissors").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
            Spacer(minLength: 0)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Self.rowHeight, height: Self.rowHeight)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(String(localized: "移除"))
                    .accessibilityLabel(String(localized: "移除 \(info.name)"))
            }
        }
        .frame(minHeight: Self.rowHeight)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: Metrics.attachmentWidth, alignment: .leading)
        .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .help(note)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note)
    }
}

/// NSTextView wrapper: Return sends unless an input method is composing; reports @ and / tokens.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var composing: Bool
    @Binding var height: CGFloat
    @Binding var query: (trigger: Character, text: String)?
    let focusToken: Int
    @Binding var replaceRequest: CompletionItem?
    let hasCompletions: Bool
    let onMove: (Int) -> Void
    let onPick: () -> Void
    let onSubmit: () -> Void
    let onPasteFiles: ([URL]) -> Void
    let onPasteImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand (not scrollableTextView()) so the text view can report marked text.
        let textView = ComposerNSTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let coordinator = context.coordinator
        textView.onMarkedTextChange = { [weak coordinator] composing in coordinator?.setComposing(composing) }
        textView.onPasteFiles = { [weak coordinator] in coordinator?.parent.onPasteFiles($0) }
        textView.onPasteImage = { [weak coordinator] in coordinator?.parent.onPasteImage($0) }
        // A draft put in before the field had its width (an example, "Ask Agent") was measured at
        // width zero and stayed one line tall with its first line cut off; so was any draft when
        // the panel was resized.
        textView.onWidthChange = { [weak coordinator, weak textView] in
            if let textView, textView.frame.width > 0 { coordinator?.recalculate(textView) }
        }
        // Text only: a text view would otherwise take a dropped file and type its path, before the
        // composer around it could attach it.
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.string])
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Spacing.xs
        textView.concealed = context.environment.panelConcealed
        coordinator.focus(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.recalculate(textView)
        }
        if let item = replaceRequest {
            DispatchQueue.main.async {
                context.coordinator.insert(item, into: textView)
                replaceRequest = nil
            }
        }
        let concealed = context.environment.panelConcealed
        if textView.concealed != concealed {
            textView.concealed = concealed
            // Hidden beneath the page, the panel gives up the keyboard; shown, it takes it, as a
            // panel built on opening did.
            if !concealed {
                context.coordinator.focus(textView)
            } else if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            context.coordinator.focus(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusToken: Int

        /// Refused while the Agent panel is concealed; a request then waits for it to open, which
        /// focuses the composer anyway.
        func focus(_ textView: ComposerNSTextView) {
            guard !textView.concealed else { return }
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusToken = parent.focusToken
        }

        func setComposing(_ composing: Bool) {
            guard parent.composing != composing else { return }
            DispatchQueue.main.async { self.parent.composing = composing }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculate(textView)
            updateQuery(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateQuery(textView)
        }

        func recalculate(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = (textView.font?.boundingRectForFont.height ?? 17).rounded(.up)
            let used = layout.usedRect(for: container).height
            let next = min(max(used, line), line * 8)
            if abs(parent.height - next) > 0.5 { DispatchQueue.main.async { self.parent.height = next } }
            textView.enclosingScrollView?.hasVerticalScroller = used > line * 8
        }

        /// The token right before the caret, if it starts with @ (anywhere) or / (at the start).
        func updateQuery(_ textView: NSTextView) {
            let string = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret <= string.length, !textView.hasMarkedText() else { return }
            let prefix = string.substring(to: caret)
            var found: (Character, String)?
            if let at = prefix.lastIndex(of: "@") {
                let token = String(prefix[prefix.index(after: at)...])
                if !token.contains("\n"), token.count <= 40, !token.contains("，"), !token.contains(",") { found = ("@", token) }
            }
            if found == nil, prefix.hasPrefix("/"), !prefix.contains(" ") { found = ("/", String(prefix.dropFirst())) }
            let current = parent.query
            if current?.trigger != found?.0 || current?.text != found?.1 {
                DispatchQueue.main.async { self.parent.query = found.map { (trigger: $0.0, text: $0.1) } }
            }
        }

        func insert(_ item: CompletionItem, into textView: NSTextView) {
            let string = textView.string as NSString
            let caret = textView.selectedRange().location
            let prefix = string.substring(to: caret)
            let start: Int
            if item.insertion.hasPrefix("/") { start = 0 }
            else if let at = prefix.range(of: "@", options: .backwards) { start = prefix.distance(from: prefix.startIndex, to: at.lowerBound) }
            else { start = caret }
            let nsStart = (prefix as NSString).length - (String(prefix.dropFirst(start)) as NSString).length
            let range = NSRange(location: nsStart, length: caret - nsStart)
            if textView.shouldChangeText(in: range, replacementString: item.insertion) {
                textView.replaceCharacters(in: range, with: item.insertion)
                textView.didChangeText()
            }
            textView.window?.makeFirstResponder(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.hasCompletions { parent.onPick(); return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if parent.hasCompletions { parent.onPick(); return true }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if parent.hasCompletions { parent.onMove(-1); return true }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if parent.hasCompletions { parent.onMove(1); return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.hasCompletions { DispatchQueue.main.async { self.parent.query = nil }; return true }
                return false
            default:
                return false
            }
        }
    }
}

/// Reports when an input method starts or finishes composing, which NSTextView does not
/// announce through textDidChange.
final class ComposerNSTextView: NSTextView {
    /// In a closed, opening or closing Agent panel, built beneath the page: it takes no keyboard
    /// focus, by request, Tab or anything else. SwiftUI's `disabled` does not reach an AppKit view.
    var concealed = false
    var onMarkedTextChange: ((Bool) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    /// The text wraps to the width, so its height has to be measured again when that changes.
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }

    /// Without these, a plain text view disables Paste for a clipboard holding only an image, as a
    /// screenshot's does, and `paste` is never called.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    /// Copied files and images become attachments; SwiftUI has no paste hook for a text view's ⌘V.
    /// Skipped by Tab; `becomeFirstResponder` refuses a direct request, which does not ask this.
    override var acceptsFirstResponder: Bool { !concealed && super.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool { !concealed && super.becomeFirstResponder() }

    override func paste(_ sender: Any?) {
        if !readAttachments(from: .general) { super.paste(sender) }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        readAttachments(from: pasteboard) || super.readSelection(from: pasteboard, type: type)
    }

    private func readAttachments(from pasteboard: NSPasteboard) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            onPasteFiles?(files)
        } else if pasteboard.string(forType: .string) == nil, let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            onPasteImage?(image)
        } else {
            return false
        }
        return true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onMarkedTextChange?(hasMarkedText())
    }
}
