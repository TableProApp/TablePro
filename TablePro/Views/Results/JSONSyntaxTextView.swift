//
//  JSONSyntaxTextView.swift
//  TablePro
//
//  Reusable NSTextView-backed JSON viewer with syntax highlighting.
//  Supports editable and read-only modes with brace matching.
//

import AppKit
import SwiftUI

internal struct JSONSyntaxTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var wordWrap: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = isEditable

        if wordWrap {
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }

        textView.delegate = context.coordinator
        textView.string = text
        Self.applyHighlighting(to: textView)

        context.coordinator.braceHelper = JSONBraceMatchingHelper(textView: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isUpdating {
            textView.string = text
            Self.applyHighlighting(to: textView)
        }
    }

    // MARK: - Syntax Highlighting

    static func applyHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let length = textStorage.length
        guard length > 0 else { return }

        let fullRange = NSRange(location: 0, length: length)
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let content = textStorage.string
        let maxHighlightLength = 10_000
        let highlightRange: NSRange
        if length > maxHighlightLength {
            highlightRange = NSRange(location: 0, length: maxHighlightLength)
        } else {
            highlightRange = fullRange
        }

        textStorage.beginEditing()

        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Apply in order: strings (red) first, then keys (blue) override string ranges,
        // then numbers and booleans. Key highlighting depends on overriding string ranges.
        applyPattern(JSONHighlightPatterns.string, color: .systemRed, in: textStorage, content: content, range: highlightRange)

        for match in JSONHighlightPatterns.key.matches(in: content, range: highlightRange) {
            let captureRange = match.range(at: 1)
            if captureRange.location != NSNotFound {
                textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: captureRange)
            }
        }

        applyPattern(JSONHighlightPatterns.number, color: .systemPurple, in: textStorage, content: content, range: highlightRange)
        applyPattern(JSONHighlightPatterns.booleanNull, color: .systemOrange, in: textStorage, content: content, range: highlightRange)

        textStorage.endEditing()
    }

    private static func applyPattern(
        _ regex: NSRegularExpression,
        color: NSColor,
        in textStorage: NSTextStorage,
        content: String,
        range: NSRange
    ) {
        for match in regex.matches(in: content, range: range) {
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    // MARK: - Coordinator

    internal final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONSyntaxTextView
        var isUpdating = false
        var braceHelper: JSONBraceMatchingHelper?
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: JSONSyntaxTextView) {
            self.parent = parent
        }

        deinit {
            highlightWorkItem?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.string
            isUpdating = false

            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak textView] in
                guard let textView else { return }
                JSONSyntaxTextView.applyHighlighting(to: textView)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            braceHelper?.updateBraceHighlight()
        }
    }
}
