import AppKit
import SwiftUI

/// Prompt editor backed by NSTextView so the composer knows the caret position for
/// `/` and `@` completion and can leave IME composition (marked text) untouched.
struct ComposerTextView: NSViewRepresentable {
    @Bindable var model: EditorModel
    @Binding var height: CGFloat
    var isEnabled: Bool

    static let minimumHeight: CGFloat = 44
    static let maximumHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = .preferredFont(forTextStyle: .body)
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.setAccessibilityLabel("对话修改配置")
        text.setAccessibilityHelp("输入 / 选择操作，输入 @ 选择服务或出口。回车发送，Shift 回车换行。")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let text = scroll.documentView as! NSTextView
        text.isEditable = isEnabled
        text.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        // Never replace text while an input method is composing.
        if !text.hasMarkedText(), text.string != model.prompt {
            text.string = model.prompt
            if model.pendingCaret == nil { text.setSelectedRange(NSRange(location: (model.prompt as NSString).length, length: 0)) }
        }
        if let caret = model.pendingCaret {
            let clamped = min(caret, (text.string as NSString).length)
            text.setSelectedRange(NSRange(location: clamped, length: 0))
            text.window?.makeFirstResponder(text)
            DispatchQueue.main.async { model.pendingCaret = nil }
        }
        context.coordinator.measure(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            if !text.hasMarkedText() { parent.model.prompt = text.string }
            refresh(text)
            measure(text)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            refresh(text)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let model = parent.model
            if model.completion != nil {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): model.moveCompletion(by: -1); return true
                case #selector(NSResponder.moveDown(_:)): model.moveCompletion(by: 1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): model.chooseCompletion(); return true
                case #selector(NSResponder.cancelOperation(_:)): model.completion = nil; return true
                default: break
                }
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                model.generate()
                return true
            }
            return false
        }

        private func refresh(_ text: NSTextView) {
            parent.model.updateCompletion(text: text.string, caret: text.selectedRange().location, composing: text.hasMarkedText())
        }

        func measure(_ text: NSTextView) {
            guard let manager = text.layoutManager, let container = text.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let target = min(max(used, ComposerTextView.minimumHeight), ComposerTextView.maximumHeight)
            if abs(target - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = target } }
        }
    }
}

/// The `/` and `@` suggestions, shown above the composer.
struct CompletionMenu: View {
    @Bindable var model: EditorModel
    var body: some View {
        if let state = model.completion {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.trigger.character == "/" ? "操作" : "服务与出口").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, EditorLayout.small).padding(.top, EditorLayout.small)
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    Button { model.chooseCompletion(index) } label: {
                        HStack(spacing: EditorLayout.small) {
                            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18)
                            Text(item.label).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: EditorLayout.small)
                            Text(item.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, EditorLayout.small).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == state.index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(index == state.index ? .isSelected : [])
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkbenchStyle.fieldRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("补全建议")
        }
    }
}
