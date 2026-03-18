//
//  JSONEditorContentView.swift
//  TablePro
//
//  SwiftUI popover content for editing JSON/JSONB column values with formatting and validation.
//

import AppKit
import SwiftUI

struct JSONEditorContentView: View {
    let initialValue: String?
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text: String
    @State private var showInvalidAlert = false

    init(
        initialValue: String?,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialValue = initialValue
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue?.prettyPrintedAsJson() ?? initialValue ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            JSONSyntaxTextView(text: $text)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveJSON() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 420, height: 340)
        .alert("Invalid JSON", isPresented: $showInvalidAlert) {
            Button("Save Anyway") { commitAndClose(text) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The text is not valid JSON. Save anyway?")
        }
    }

    // MARK: - Actions

    private func saveJSON() {
        guard !text.isEmpty else {
            commitAndClose(text)
            return
        }

        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            showInvalidAlert = true
            return
        }

        commitAndClose(text)
    }

    private func commitAndClose(_ value: String) {
        let saveValue = Self.compact(value) ?? value
        if saveValue != initialValue {
            onCommit(saveValue)
        }
        onDismiss()
    }

    // MARK: - JSON Helpers

    private static func compact(_ jsonString: String?) -> String? {
        guard let data = jsonString?.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let compactData = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.withoutEscapingSlashes]
              ),
              let compactString = String(data: compactData, encoding: .utf8) else {
            return nil
        }
        return compactString
    }
}

// MARK: - JSON Syntax Highlighted Text View

private struct JSONSyntaxTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: ThemeEngine.shared.activeTheme.typography.medium, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false

        textView.delegate = context.coordinator
        textView.string = text
        Self.applyHighlighting(to: textView)

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
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: ThemeEngine.shared.activeTheme.typography.medium, weight: .regular)
        let content = textStorage.string
        let maxHighlightLength = 10_000
        let highlightRange: NSRange
        if length > maxHighlightLength {
            highlightRange = NSRange(location: 0, length: maxHighlightLength)
        } else {
            highlightRange = fullRange
        }

        textStorage.beginEditing()

        // Reset to base style
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONSyntaxTextView
        var isUpdating = false
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

            // Debounce syntax highlighting to avoid 4 regex passes per keystroke
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak textView] in
                guard let textView else { return }
                JSONSyntaxTextView.applyHighlighting(to: textView)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }
    }
}
