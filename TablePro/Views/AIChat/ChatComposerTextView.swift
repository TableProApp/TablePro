//
//  ChatComposerTextView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let mentionState: MentionPopoverState
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onAttach: (ContextItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ChatComposerScrollContainer {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.placeholderString = placeholder
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text

        let container = ChatComposerScrollContainer(
            textView: textView,
            minLines: minLines,
            maxLines: maxLines
        )
        context.coordinator.scrollContainer = container
        return container
    }

    func updateNSView(_ container: ChatComposerScrollContainer, context: Context) {
        context.coordinator.parent = self
        let textView = container.textView
        if textView.string != text {
            context.coordinator.isUpdatingFromBinding = true
            textView.string = text
            context.coordinator.isUpdatingFromBinding = false
            container.invalidateIntrinsicContentSize()
        }
        context.coordinator.syncPopover()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        weak var scrollContainer: ChatComposerScrollContainer?
        var isUpdatingFromBinding = false
        private var popover: NSPopover?
        private var hostingController: NSHostingController<MentionSuggestionListView>?

        init(parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromBinding,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            scrollContainer?.invalidateIntrinsicContentSize()
            parent.onTextChange(textView.string, textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingFromBinding,
                  let textView = notification.object as? NSTextView else { return }
            parent.onTextChange(textView.string, textView.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
                return handleEnter(in: textView)
            case #selector(NSStandardKeyBindingResponding.cancelOperation(_:)):
                return handleEscape()
            case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
                return handleArrow(delta: 1)
            case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
                return handleArrow(delta: -1)
            case #selector(NSStandardKeyBindingResponding.insertTab(_:)):
                if parent.mentionState.isVisible {
                    commitSelectedMention(in: textView)
                    return true
                }
                return false
            default:
                return false
            }
        }

        func syncPopover() {
            guard let textView = scrollContainer?.textView else { return }
            if parent.mentionState.isVisible, !parent.mentionState.candidates.isEmpty {
                showOrUpdatePopover(textView: textView)
            } else {
                dismissPopover()
            }
        }

        private func handleEnter(in textView: NSTextView) -> Bool {
            if parent.mentionState.isVisible, !parent.mentionState.candidates.isEmpty {
                commitSelectedMention(in: textView)
                return true
            }
            if NSEvent.modifierFlags.contains(.shift) {
                return false
            }
            parent.onSubmit()
            return true
        }

        private func handleEscape() -> Bool {
            guard parent.mentionState.isVisible else { return false }
            parent.mentionState.reset()
            dismissPopover()
            return true
        }

        private func handleArrow(delta: Int) -> Bool {
            guard parent.mentionState.isVisible, !parent.mentionState.candidates.isEmpty else {
                return false
            }
            parent.mentionState.moveSelection(by: delta)
            return true
        }

        private func showOrUpdatePopover(textView: NSTextView) {
            guard let rect = caretRect(in: textView) else {
                dismissPopover()
                return
            }
            if popover == nil {
                let listView = MentionSuggestionListView(
                    state: parent.mentionState,
                    onSelect: { [weak self, weak textView] index in
                        guard let self, let textView else { return }
                        self.parent.mentionState.selectedIndex = index
                        self.commitSelectedMention(in: textView)
                    }
                )
                let hosting = NSHostingController(rootView: listView)
                hosting.sizingOptions = NSHostingSizingOptions.preferredContentSize
                let newPopover = NSPopover()
                newPopover.behavior = .transient
                newPopover.animates = false
                newPopover.contentViewController = hosting
                self.hostingController = hosting
                self.popover = newPopover
            }
            guard let popover else { return }
            if popover.isShown {
                popover.positioningRect = rect
            } else {
                popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            }
        }

        private func dismissPopover() {
            popover?.performClose(nil)
        }

        private func caretRect(in textView: NSTextView) -> NSRect? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let nsText = textView.string as NSString
            let caret = min(textView.selectedRange().location, nsText.length)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 0),
                in: textContainer
            )
            let origin = textView.textContainerOrigin
            var rect = glyphRect.offsetBy(dx: origin.x, dy: origin.y)
            if rect.width < 1 { rect.size.width = 1 }
            return rect
        }

        private func commitSelectedMention(in textView: NSTextView) {
            guard let candidate = parent.mentionState.selectedCandidate else { return }
            let range = parent.mentionState.anchorRange
            let nsText = textView.string as NSString
            guard range.location >= 0,
                  NSMaxRange(range) <= nsText.length else {
                parent.mentionState.reset()
                dismissPopover()
                return
            }
            if textView.shouldChangeText(in: range, replacementString: "") {
                textView.replaceCharacters(in: range, with: "")
                textView.didChangeText()
            }
            parent.onAttach(candidate.item)
            parent.mentionState.reset()
            dismissPopover()
        }
    }
}

@MainActor
final class ChatComposerNSTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: inset.width + padding, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}

@MainActor
final class ChatComposerScrollContainer: NSView {
    let textView: ChatComposerNSTextView
    private let scrollView: NSScrollView
    private let minLines: Int
    private let maxLines: Int

    init(textView: ChatComposerNSTextView, minLines: Int, maxLines: Int) {
        self.textView = textView
        self.minLines = minLines
        self.maxLines = maxLines
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        self.scrollView = scroll
        super.init(frame: .zero)
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let lineHeight = textView.font?.boundingRectForFont.height ?? 17
        let insetHeight = textView.textContainerInset.height * 2
        let minHeight = lineHeight * CGFloat(minLines) + insetHeight + 4
        let maxHeight = lineHeight * CGFloat(maxLines) + insetHeight + 4
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(minHeight))
        }
        let used = layoutManager.usedRect(for: textContainer).height
        let content = used + insetHeight + 4
        let clamped = max(minHeight, min(content, maxHeight))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(clamped))
    }
}
