//
//  PromptPassphraseProvider.swift
//  TablePro
//
//  Prompts the user for an SSH key passphrase via a modal NSAlert dialog.
//  Used when the agent auth fallback tries a key file that requires a passphrase
//  the user hasn't configured in the connection UI.
//

import AppKit
import Foundation

internal final class PromptPassphraseProvider: @unchecked Sendable {
    private let keyPath: String

    init(keyPath: String) {
        self.keyPath = keyPath
    }

    func providePassphrase() -> String? {
        if Thread.isMainThread {
            return showAlert()
        }

        let semaphore = DispatchSemaphore(value: 0)
        var passphrase: String?
        DispatchQueue.main.async {
            passphrase = self.showAlert()
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + 120)
        guard result == .success else { return nil }
        return passphrase
    }

    private func showAlert() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "SSH Key Passphrase Required")
        let keyName = (keyPath as NSString).lastPathComponent
        alert.informativeText = String(
            format: String(localized: "Enter the passphrase for SSH key \"%@\":"),
            keyName
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = String(localized: "Passphrase")
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? textField.stringValue : nil
    }
}
