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
    private let attempt: SSHConnectionAttempt?
    private let timeoutEndpoint: ConnectionTimeoutEndpoint?

    init(
        keyPath: String,
        attempt: SSHConnectionAttempt? = nil,
        timeoutEndpoint: ConnectionTimeoutEndpoint? = nil
    ) {
        self.keyPath = keyPath
        self.attempt = attempt
        self.timeoutEndpoint = timeoutEndpoint
    }

    func providePassphrase() throws -> PassphrasePromptResult? {
        if Thread.isMainThread {
            return try showAlert()
        }
        return try DispatchQueue.main.sync { try showAlert() }
    }

    private func showAlert() throws -> PassphrasePromptResult? {
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

        let width: CGFloat = 260
        let fieldHeight: CGFloat = 22
        let checkboxHeight: CGFloat = 18
        let spacing: CGFloat = 8
        let totalHeight = fieldHeight + spacing + checkboxHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))

        let textField = NSSecureTextField(frame: NSRect(
            x: 0, y: checkboxHeight + spacing,
            width: width, height: fieldHeight
        ))
        textField.placeholderString = String(localized: "Passphrase")
        container.addSubview(textField)

        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "Save passphrase in Keychain"),
            target: nil,
            action: nil
        )
        checkbox.frame = NSRect(x: 0, y: 0, width: width, height: checkboxHeight)
        checkbox.state = .on
        container.addSubview(checkbox)

        alert.accessoryView = container
        alert.window.initialFirstResponder = textField

        let promptId: UUID?
        if let timeoutEndpoint {
            promptId = try attempt?.registerPrompt(for: timeoutEndpoint) {
                if NSApp.modalWindow === alert.window {
                    NSApp.abortModal()
                }
                alert.window.orderOut(nil)
            }
        } else {
            promptId = nil
        }
        defer {
            if let promptId {
                attempt?.unregisterPrompt(promptId)
            }
        }

        let response = alert.runModal()
        if let timeoutEndpoint {
            try attempt?.check(for: timeoutEndpoint)
        }
        guard response == .alertFirstButtonReturn,
              !textField.stringValue.isEmpty else { return nil }

        return PassphrasePromptResult(
            passphrase: textField.stringValue,
            saveToKeychain: checkbox.state == .on
        )
    }
}
