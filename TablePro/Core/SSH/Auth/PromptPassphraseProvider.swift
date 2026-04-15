//
//  PromptPassphraseProvider.swift
//  TablePro
//
//  Prompts the user for an SSH key passphrase via a modal NSAlert dialog.
//  Optionally offers to save the passphrase to the macOS Keychain,
//  matching the native ssh-add --apple-use-keychain behavior.
//

import AppKit
import Foundation

internal struct PassphrasePromptResult: Sendable {
    let passphrase: String
    let saveToKeychain: Bool
}

internal final class PromptPassphraseProvider: @unchecked Sendable {
    private let keyPath: String

    init(keyPath: String) {
        self.keyPath = keyPath
    }

    func providePassphrase() -> PassphrasePromptResult? {
        if Thread.isMainThread {
            return showAlert()
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: PassphrasePromptResult?
        DispatchQueue.main.async {
            result = self.showAlert()
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 120)
        guard waitResult == .success else { return nil }
        return result
    }

    private func showAlert() -> PassphrasePromptResult? {
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

        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "Save passphrase in Keychain"),
            target: nil,
            action: nil
        )
        checkbox.state = .on

        let stackView = NSStackView(views: [textField, checkbox])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        alert.accessoryView = stackView
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              !textField.stringValue.isEmpty else { return nil }

        return PassphrasePromptResult(
            passphrase: textField.stringValue,
            saveToKeychain: checkbox.state == .on
        )
    }
}
