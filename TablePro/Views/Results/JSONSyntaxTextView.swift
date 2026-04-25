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

        context.coordinator.braceHelper = JSONBraceMatchingHelper(textView: textView)
        context.coordinator.observeScroll(of: scrollView)

        DispatchQueue.main.async { [coordinator = context.coordinator] in
            coordinator.highlightVisible()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isUpdating {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if isEditable,
               textView.shouldChangeText(in: fullRange, replacementString: text) {
                context.coordinator.isUpdating = true
                textView.textStorage?.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
                context.coordinator.isUpdating = false
            } else {
                textView.string = text
            }
            context.coordinator.highlightedSet = IndexSet()
            context.coordinator.highlightVisible()
        }
    }

    // MARK: - Syntax Highlighting

    static func applyHighlighting(to textView: NSTextView, range highlightRange: NSRange, highlightedSet: inout IndexSet) {
        guard let textStorage = textView.textStorage else { return }
        let length = textStorage.length
        guard length > 0 else { return }

        let clamped = NSIntersectionRange(highlightRange, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return }

        let requestedIndices = IndexSet(integersIn: clamped.location..<(clamped.location + clamped.length))
        let newIndices = requestedIndices.subtracting(highlightedSet)
        guard !newIndices.isEmpty else { return }

        let maxBatchSize = 20_000
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let content = textStorage.string

        textStorage.beginEditing()

        var processed = 0
        for range in newIndices.rangeView {
            if processed >= maxBatchSize { break }
            let cappedLength = min(range.count, maxBatchSize - processed)
            let nsRange = NSRange(location: range.lowerBound, length: cappedLength)
            textStorage.addAttribute(.font, value: font, range: nsRange)
            textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: nsRange)

            applyPattern(JSONHighlightPatterns.string, color: .systemRed, in: textStorage, content: content, range: nsRange)

            for match in JSONHighlightPatterns.key.matches(in: content, range: nsRange) {
                let captureRange = match.range(at: 1)
                if captureRange.location != NSNotFound {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: captureRange)
                }
            }

            applyPattern(JSONHighlightPatterns.number, color: .systemPurple, in: textStorage, content: content, range: nsRange)
            applyPattern(JSONHighlightPatterns.booleanNull, color: .systemOrange, in: textStorage, content: content, range: nsRange)

            highlightedSet.insert(integersIn: nsRange.location..<(nsRange.location + nsRange.length))
            processed += cappedLength
        }

        textStorage.endEditing()
    }

    static func visibleCharacterRange(for textView: NSTextView) -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
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
        private var scrollObserver: NSObjectProtocol?

        init(_ parent: JSONSyntaxTextView) {
            self.parent = parent
        }

        deinit {
            highlightWorkItem?.cancel()
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        weak var scrollView: NSScrollView?
        var highlightedSet = IndexSet()

        func observeScroll(of scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.highlightVisible()
            }
        }

        func highlightVisible() {
            guard let textView = scrollView?.documentView as? NSTextView,
                  let visible = JSONSyntaxTextView.visibleCharacterRange(for: textView) else {
                return
            }
            let nsString = textView.string as NSString
            let length = nsString.length
            let buffer = 8_000
            let rawStart = max(0, visible.location - buffer)
            let rawEnd = min(length, visible.location + visible.length + buffer)

            let lineStart = nsString.lineRange(for: NSRange(location: rawStart, length: 0)).location
            let lineEndRange = nsString.lineRange(for: NSRange(location: rawEnd > 0 ? rawEnd - 1 : 0, length: 0))
            let lineEnd = min(length, lineEndRange.location + lineEndRange.length)

            let buffered = NSRange(location: lineStart, length: lineEnd - lineStart)
            JSONSyntaxTextView.applyHighlighting(to: textView, range: buffered, highlightedSet: &highlightedSet)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.string
            isUpdating = false

            highlightedSet = IndexSet()
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.highlightVisible()
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            braceHelper?.updateBraceHighlight()
        }
    }
}
