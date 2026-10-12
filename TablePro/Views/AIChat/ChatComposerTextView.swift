//
//  ChatComposerTextView.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let isCommittingMention: Bool
    let acceptsImages: Bool
    let paintsHighlight: Bool
    let highlightEnabled: Bool
    let onToggleHighlight: () -> Void
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onCommitMention: () -> Bool
    let onArrow: (Int) -> Bool
    let onTab: () -> Bool
    let onEscape: () -> Bool
    let onPasteImageData: (Data, String) -> Void
    let onPasteImageFailed: (String) -> Void

    func makeNSView(context: Context) -> ChatComposerScrollView {
        let textView = ChatComposerNSTextView.make()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.acceptsImagePaste = acceptsImages
        textView.onPasteImageData = onPasteImageData
        textView.onPasteImageFailed = onPasteImageFailed
        textView.highlightEnabled = highlightEnabled
        textView.onToggleHighlight = onToggleHighlight

        let scrollView = ChatComposerScrollView.make(documentView: textView)
        scrollView.minLines = minLines
        scrollView.maxLines = maxLines
        scrollView.focusRingType = ComposerHighlightPreference.focusRingType(paintsHighlight: paintsHighlight)

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
        textView.highlightEnabled = highlightEnabled
        textView.onToggleHighlight = onToggleHighlight

        let ringType = ComposerHighlightPreference.focusRingType(paintsHighlight: paintsHighlight)
        if scrollView.focusRingType != ringType {
            scrollView.focusRingType = ringType
            scrollView.noteFocusRingMaskChanged()
        }

        // Replacing the string outright while an input method has marked text cancels the
        // composition. Routing through shouldChangeText/didChangeText also keeps the undo
        // stack and the delegate notifications intact.
        if textView.string != text, !textView.hasMarkedText() {
            let selected = textView.selectedRange()
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: full, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: full, with: text)
                textView.didChangeText()
            }
            let clampedLocation = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
        }

        textView.placeholder = placeholder

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
    /// The placeholder is painted in `draw(_:)`, which the accessibility tree never sees, so the
    /// only thing that names this field to VoiceOver is the value set here. Keeping the two
    /// together means no assignment path can leave the field nameless: guarding the call at one
    /// caller is what left it unset since #2097, because `makeNSView` had already stored the same
    /// string and the caller's comparison was never true again.
    var placeholder: String = "" {
        didSet {
            guard oldValue != placeholder else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    var placeholderColor: NSColor = .placeholderTextColor
    var onFocusChange: ((Bool) -> Void)?
    var onSizeChange: (() -> Void)?
    var acceptsImagePaste: Bool = false
    var onPasteImageData: ((Data, String) -> Void)?
    var onPasteImageFailed: ((String) -> Void)?
    var highlightEnabled: Bool = true
    var onToggleHighlight: (() -> Void)?

    static func make() -> ChatComposerNSTextView {
        let textView = ChatComposerNSTextView()
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
        return textView
    }

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

    /// Measured on macOS 27: unparenting the pane moves the window's first responder away without
    /// ever sending `resignFirstResponder` here, so focus has to be re-read from the window rather
    /// than waited for. Switching the trailing pane away and back otherwise left the composer
    /// believing it still held focus, and the highlight painted over a field that did not.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onFocusChange?(window?.firstResponder === self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: String(localized: "Highlight When Focused"),
            action: #selector(toggleComposerHighlight(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = highlightEnabled ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc private func toggleComposerHighlight(_ sender: Any?) {
        onToggleHighlight?()
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var truncating = attributes
        truncating[.paragraphStyle] = paragraph
        let available = NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: max(bounds.width - textContainerInset.width * 2, 0),
            height: font.boundingRectForFont.height
        )
        (placeholder as NSString).draw(
            with: available,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: truncating,
            context: nil
        )
    }

    override func paste(_ sender: Any?) {
        guard acceptsImagePaste, let onPasteImageData else {
            super.paste(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            onPasteImageData(data, UTType.png.identifier)
            return
        }
        if let data = pasteboard.data(forType: .tiff) {
            onPasteImageData(data, UTType.tiff.identifier)
            return
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let fileURL = urls.first(where: { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false }) {
            /// Identifying the file and reading it are separate answers. Folding the read into the
            /// same `if let` made an unreadable image (an iCloud file still in the cloud, a network
            /// volume that went away) fall through to `super.paste`, which pastes its path as text
            /// into the prompt. The user asked for the picture and silently got a file URL.
            do {
                let data = try Data(contentsOf: fileURL)
                let uti = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
                    ?? UTType.image.identifier
                onPasteImageData(data, uti)
            } catch {
                onPasteImageFailed?(error.localizedDescription)
            }
            return
        }
        super.paste(sender)
    }
}

final class ChatComposerScrollView: NSScrollView {
    var minLines: Int = 1
    var maxLines: Int = 5

    static func make(documentView textView: NSTextView) -> ChatComposerScrollView {
        let scrollView = ChatComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.size = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    /// The composer's rounded surface is drawn by SwiftUI, so AppKit has to be told the shape to
    /// wrap; left to itself it rings the square bounds. This is the shape `ShortcutRecorderNSView`
    /// uses for the same job, and the radius is the one the SwiftUI background reads.
    ///
    /// The document view carries the focus, but the ring belongs on the scroll view: measured on
    /// macOS 27, `focusRingType` on the text view never produces a `drawFocusRingMask` call, while
    /// on the scroll view it does, `.noBorder` included.
    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: ChatComposerMetrics.cornerRadius,
            yRadius: ChatComposerMetrics.cornerRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    /// The mask is derived from `bounds`, and the composer grows from one line to five as the user
    /// types, so the cached ring has to be invalidated with the size that produced it.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { noteFocusRingMaskChanged() }
    }

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
        layoutManager.ensureLayout(
            forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: maxHeight),
            in: container
        )
        let used = layoutManager.usedRect(for: container).height
        let content = used + verticalPadding
        return NSSize(width: NSView.noIntrinsicMetric, height: max(minHeight, min(maxHeight, content)))
    }
}
