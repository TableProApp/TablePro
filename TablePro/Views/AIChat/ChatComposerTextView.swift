//
//  ChatComposerTextView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let isCommittingMention: Bool
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onCommitMention: () -> Bool
    let onArrow: (Int) -> Bool
    let onTab: () -> Bool
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> ChatComposerScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 14, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder

        let scrollView = ChatComposerScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.verticalScrollElasticity = .allowed
        scrollView.minLines = minLines
        scrollView.maxLines = maxLines

        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.handleFocusChange(focused)
        }
        textView.onSizeChange = { [weak scrollView] in
            scrollView?.invalidateIntrinsicContentSize()
        }

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.refresh(from: self)

        if textView.string != text {
            textView.string = text
        }

        return scrollView
    }

    func updateNSView(_ scrollView: ChatComposerScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatComposerNSTextView else { return }

        context.coordinator.refresh(from: self)
        scrollView.minLines = minLines
        scrollView.maxLines = maxLines

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let clampedLocation = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
        }

        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        scrollView.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: ChatComposerNSTextView?
        weak var scrollView: ChatComposerScrollView?

        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var isCommittingMention: Bool = false
        private var onTextChange: (String, Int) -> Void = { _, _ in }
        private var onSubmit: () -> Void = {}
        private var onCommitMention: () -> Bool = { false }
        private var onArrow: (Int) -> Bool = { _ in false }
        private var onTab: () -> Bool = { false }
        private var onEscape: () -> Bool = { false }

        init(parent: ChatComposerTextView) {
            self.text = parent._text
            self.isFocused = parent._isFocused
            super.init()
            refresh(from: parent)
        }

        func refresh(from parent: ChatComposerTextView) {
            self.text = parent._text
            self.isFocused = parent._isFocused
            self.isCommittingMention = parent.isCommittingMention
            self.onTextChange = parent.onTextChange
            self.onSubmit = parent.onSubmit
            self.onCommitMention = parent.onCommitMention
            self.onArrow = parent.onArrow
            self.onTab = parent.onTab
            self.onEscape = parent.onEscape
        }

        func handleFocusChange(_ focused: Bool) {
            guard isFocused.wrappedValue != focused else { return }
            DispatchQueue.main.async { [isFocused] in
                isFocused.wrappedValue = focused
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            text.wrappedValue = newText
            scrollView?.invalidateIntrinsicContentSize()
            guard !isCommittingMention else { return }
            let caret = textView.selectedRange().location
            onTextChange(newText, caret)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift) || modifiers.contains(.option) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                if !onCommitMention() {
                    onSubmit()
                }
                return true

            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true

            case #selector(NSResponder.moveUp(_:)):
                return onArrow(-1)

            case #selector(NSResponder.moveDown(_:)):
                return onArrow(1)

            case #selector(NSResponder.insertTab(_:)):
                if onTab() { return true }
                textView.window?.selectNextKeyView(textView)
                return true

            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(textView)
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                return onEscape()

            default:
                return false
            }
        }
    }
}

final class ChatComposerNSTextView: NSTextView {
    var placeholder: String = ""
    var placeholderColor: NSColor = .placeholderTextColor
    var onFocusChange: ((Bool) -> Void)?
    var onSizeChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        onSizeChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let font = self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: placeholderColor
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}

final class ChatComposerScrollView: NSScrollView {
    var minLines: Int = 1
    var maxLines: Int = 5

    override var intrinsicContentSize: NSSize {
        guard
            let textView = documentView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            return super.intrinsicContentSize
        }
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let inset = textView.textContainerInset
        let verticalPadding = inset.height * 2
        let minHeight = CGFloat(minLines) * lineHeight + verticalPadding
        let maxHeight = CGFloat(maxLines) * lineHeight + verticalPadding
        let used = layoutManager.usedRect(for: container).height
        let content = used + verticalPadding
        return NSSize(width: NSView.noIntrinsicMetric, height: max(minHeight, min(maxHeight, content)))
    }
}
