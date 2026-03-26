
//
//  TPEditorView.swift
//  TablePro
//
//  NSViewRepresentable SwiftUI wrapper for the NSTextView-based SQL editor.
//  Assembles the TextKit 1 stack: NSTextStorage → NSLayoutManager → NSTextContainer → TPTextView.
//

import AppKit
import SwiftUI

struct TPEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorRange: NSRange
    var configuration: TPEditorConfiguration
    var editorDelegate: TPEditorDelegate?
    var onTextViewCreated: ((TPTextView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 1. Assemble TextKit 1 stack in Apple's documented order
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = configuration.wrapLines
        textContainer.heightTracksTextView = false
        if !configuration.wrapLines {
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.addTextContainer(textContainer)

        // 2. Text view
        let textView = TPTextView(frame: .zero, textContainer: textContainer)
        textView.configureForCodeEditing(configuration: configuration)
        textView.editorDelegate = editorDelegate
        textView.delegate = context.coordinator

        // 3. Scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !configuration.wrapLines
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Size the text view to fill the scroll view initially
        textView.autoresizingMask = [.width, .height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        // 4. Line number gutter
        if configuration.showLineNumbers {
            let gutter = TPLineNumberView(scrollView: scrollView, orientation: .verticalRuler)
            gutter.font = configuration.font.rulerFont
            gutter.textColor = configuration.theme.text.withAlphaComponent(0.35)
            gutter.currentLineTextColor = configuration.theme.text
            gutter.backgroundColor = configuration.theme.background
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        // 5. Store references and install highlighter
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.highlighter.install(on: textView)

        // 6. Observe scroll to re-highlight newly visible regions
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        // 7. Apply scroll mode (after documentView is set)
        textView.configureScrollMode(wrapLines: configuration.wrapLines)

        // 8. Initial content and highlighting
        textView.setContent(text)
        context.coordinator.highlighter.highlightVisibleRange()

        // 9. Notify caller that the text view is ready
        context.coordinator.parent.onTextViewCreated?(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        // Prevent feedback loops during programmatic updates
        guard !coordinator.isUpdatingFromDelegate else { return }

        // Sync text if changed externally
        let currentText = textView.string as NSString
        let newText = text as NSString
        if currentText.length != newText.length || currentText != newText {
            coordinator.isUpdatingFromNSView = true
            textView.setContent(text)
            coordinator.isUpdatingFromNSView = false
        }

        // Sync configuration changes
        if coordinator.lastConfiguration != configuration {
            textView.applyConfiguration(configuration)
            textView.configureScrollMode(wrapLines: configuration.wrapLines)

            scrollView.hasHorizontalScroller = !configuration.wrapLines

            if let gutter = scrollView.verticalRulerView as? TPLineNumberView {
                gutter.font = configuration.font.rulerFont
                gutter.textColor = configuration.theme.text.withAlphaComponent(0.35)
                gutter.currentLineTextColor = configuration.theme.text
                gutter.backgroundColor = configuration.theme.background
            }

            scrollView.rulersVisible = configuration.showLineNumbers
            coordinator.highlighter.updateTheme(configuration.theme)
            coordinator.lastConfiguration = configuration
        }

        // Sync editor delegate
        textView.editorDelegate = editorDelegate
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TPEditorView
        weak var textView: TPTextView?
        weak var scrollView: NSScrollView?
        let highlighter: TPSyntaxHighlighter
        var lastConfiguration: TPEditorConfiguration?
        var isUpdatingFromNSView = false
        var isUpdatingFromDelegate = false

        init(parent: TPEditorView) {
            self.parent = parent
            self.highlighter = TPSyntaxHighlighter(theme: parent.configuration.theme)
            super.init()
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TPTextView else { return }

            // Forward to highlighter
            highlighter.textDidChange(notification)

            guard !isUpdatingFromNSView else { return }

            isUpdatingFromDelegate = true
            parent.text = textView.string
            isUpdatingFromDelegate = false

            textView.editorDelegate?.editorDidChangeText(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? TPTextView else { return }
            guard !isUpdatingFromNSView else { return }

            let range = textView.selectedRange()
            isUpdatingFromDelegate = true
            parent.cursorRange = range
            isUpdatingFromDelegate = false

            textView.editorDelegate?.editorDidChangeSelection(textView, range: range)
        }

        // MARK: - Scroll Observer

        @objc func scrollViewDidScroll(_ notification: Notification) {
            highlighter.highlightVisibleRange()
        }
    }
}

// MARK: - NSFont Ruler Helper

private extension NSFont {
    var rulerFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(pointSize - 1, 9), weight: .regular)
    }
}
