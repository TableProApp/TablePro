//
//  PasswordPromptHelper.swift
//  TablePro
//
//  Prompts the user for a database password via a native modal alert.
//

import AppKit

enum PasswordPromptHelper {
    /// Presents a modal alert with a secure text field to collect a password or API token.
    /// Returns the entered value (may be empty for passwordless databases), or `nil` if the user cancels.
    @MainActor
    static func prompt(connectionName: String, isAPIToken: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = isAPIToken
            ? String(localized: "API Token Required")
            : String(localized: "Password Required")
        alert.informativeText = String(
            format: String(localized: "Enter the %@ for \"%@\""),
            isAPIToken ? String(localized: "API token") : String(localized: "password"),
            connectionName
        )
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = isAPIToken
            ? String(localized: "API Token") : String(localized: "Password")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }
}
