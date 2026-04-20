//
//  CompletionTextField.swift
//  TablePro
//
//  NSTextField with native macOS autocompletion via custom field editor.
//

import AppKit
import SwiftUI

struct CompletionTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var completions: [String] = []
    var shouldFocus: Bool = false
    var allowsMultiLine: Bool = false
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> CompletionNSTextField {
        let textField = CompletionNSTextField()
        textField.placeholderString = placeholder
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .small
        textField.font = .systemFont(ofSize: 12)
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.completionItems = completions

        if allowsMultiLine {
            textField.usesSingleLineMode = false
            textField.cell?.wraps = true
            textField.cell?.isScrollable = false
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0
        } else {
            textField.lineBreakMode = .byTruncatingTail
        }

        if shouldFocus {
            DispatchQueue.main.async {
                textField.window?.makeFirstResponder(textField)
            }
        }

        return textField
    }

    func updateNSView(_ textField: CompletionNSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.completionItems = completions
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        private var previousTextLength = 0

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let newValue = textField.stringValue
            let newLength = (newValue as NSString).length
            let grew = newLength > previousTextLength
            previousTextLength = newLength
            text.wrappedValue = newValue

            if grew, !newValue.isEmpty,
               let fieldEditor = textField.currentEditor() as? NSTextView
            {
                fieldEditor.complete(nil)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            previousTextLength = 0
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            // Option+Enter → insert newline (standard macOS behavior)
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                text.wrappedValue = textView.string
                previousTextLength = (textView.string as NSString).length
                return true
            }
            return false
        }
    }
}

// MARK: - NSTextField with Custom Cell

final class CompletionNSTextField: NSTextField {
    var completionItems: [String] = [] {
        didSet {
            (cell as? CompletionTextFieldCell)?.completionItems = completionItems
        }
    }

    override class var cellClass: AnyClass? {
        get { CompletionTextFieldCell.self }
        set {}
    }
}

// MARK: - Custom Cell (provides field editor)

private final class CompletionTextFieldCell: NSTextFieldCell {
    var completionItems: [String] = []
    private var customFieldEditor: CompletionFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if customFieldEditor == nil {
            let editor = CompletionFieldEditor()
            editor.isFieldEditor = true
            customFieldEditor = editor
        }
        customFieldEditor?.completionItems = completionItems
        return customFieldEditor
    }
}

// MARK: - Custom Field Editor (native completion)

private final class CompletionFieldEditor: NSTextView {
    var completionItems: [String] = []

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        index.pointee = -1

        guard charRange.length > 0 else { return nil }

        let partial = (string as NSString).substring(with: charRange).lowercased()
        let matches = completionItems.filter { $0.lowercased().hasPrefix(partial) }

        // Don't show popup when the only match is exactly what's typed
        if matches.count == 1, matches[0].lowercased() == partial {
            return nil
        }

        return matches.isEmpty ? nil : matches
    }
}
