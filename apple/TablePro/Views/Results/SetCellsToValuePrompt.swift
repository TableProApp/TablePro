//
//  SetCellsToValuePrompt.swift
//  TablePro
//

import AppKit

@MainActor
enum SetCellsToValuePrompt {
    static func present(informative: String, window: NSWindow?, completion: @escaping (String?) -> Void) {
        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Value")
        field.setAccessibilityLabel(String(localized: "Value"))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)

        let alert = NSAlert()
        alert.messageText = String(localized: "Set Cells to Value")
        alert.informativeText = informative
        alert.addButton(withTitle: String(localized: "Set"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        AlertHelper.present(alert, in: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}
