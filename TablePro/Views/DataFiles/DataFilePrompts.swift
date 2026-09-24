//
//  DataFilePrompts.swift
//  TablePro
//

import AppKit
import TableProTabular

@MainActor
enum DataFilePrompts {
    static func columnName(title: String, initial: String, window: NSWindow?, completion: @escaping (String?) -> Void) {
        let field = textField(initial: initial, placeholder: String(localized: "Column name"))
        present(
            message: title,
            confirm: String(localized: "OK"),
            accessory: field,
            window: window
        ) { confirmed in
            completion(confirmed ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
    }

    static func value(window: NSWindow?, completion: @escaping (String?) -> Void) {
        let field = textField(initial: "", placeholder: String(localized: "Value"))
        present(
            message: String(localized: "Set Cells to Value"),
            informative: String(localized: "Every targeted cell gets this value."),
            confirm: String(localized: "Set"),
            accessory: field,
            window: window
        ) { confirmed in
            completion(confirmed ? field.stringValue : nil)
        }
    }

    static func splitSeparator(window: NSWindow?, completion: @escaping (TabularSplitSeparator?) -> Void) {
        let field = textField(initial: ",", placeholder: String(localized: "Separator"))
        let regexToggle = NSButton(checkboxWithTitle: String(localized: "Regular Expression"), target: nil, action: nil)
        present(
            message: String(localized: "Split Column"),
            informative: String(localized: "Each value is split at every match. Rows with fewer pieces get empty cells."),
            confirm: String(localized: "Split"),
            accessory: stack([field, regexToggle]),
            window: window
        ) { confirmed in
            guard confirmed, !field.stringValue.isEmpty else {
                completion(nil)
                return
            }
            guard regexToggle.state == .on else {
                completion(.literal(field.stringValue))
                return
            }
            guard let expression = try? NSRegularExpression(pattern: field.stringValue) else {
                presentInvalidPattern(window: window)
                completion(nil)
                return
            }
            completion(.regularExpression(expression))
        }
    }

    static func mergeSeparator(window: NSWindow?, completion: @escaping (String?) -> Void) {
        let field = textField(initial: " ", placeholder: String(localized: "Separator"))
        present(
            message: String(localized: "Merge Columns"),
            informative: String(localized: "Joins this column with the one to its right."),
            confirm: String(localized: "Merge"),
            accessory: field,
            window: window
        ) { confirmed in
            completion(confirmed ? field.stringValue : nil)
        }
    }

    private static func presentInvalidPattern(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Invalid regular expression")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        AlertHelper.present(alert, in: window) { _ in }
    }

    private static func textField(initial: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        return field
    }

    private static func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        return stack
    }

    private static func present(
        message: String,
        informative: String? = nil,
        confirm: String,
        accessory: NSView,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        if let informative {
            alert.informativeText = informative
        }
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = accessory is NSTextField ? accessory : accessory.subviews.first
        AlertHelper.present(alert, in: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}

@MainActor
enum DataFileDeleteConfirmation {
    static func rowDeleteTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Delete this row?")
            : String(format: String(localized: "Delete %lld rows?"), count)
    }

    static func columnDeleteTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Delete this column?")
            : String(format: String(localized: "Delete %lld columns?"), count)
    }

    static func confirm(messageText: String, window: NSWindow?, proceed: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.alertStyle = .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: String(localized: "Delete"),
            cancelButton: String(localized: "Cancel")
        )
        AlertHelper.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed()
        }
    }
}
