//
//  PromptTOTPProvider.swift
//  TablePro
//

import AppKit
import Foundation

/// Prompts the user for a TOTP code via a modal NSAlert dialog.
///
/// This provider blocks the calling thread while the alert is displayed on the main thread.
/// It is intended for interactive SSH sessions where no TOTP secret is configured.
internal final class PromptTOTPProvider: TOTPProvider, @unchecked Sendable {
    func provideCode() throws -> String {
        if Thread.isMainThread {
            return try handleResult(showAlert())
        }

        let semaphore = DispatchSemaphore(value: 0)
        var code: String?
        DispatchQueue.main.async {
            code = self.showAlert()
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + 120)
        guard result == .success else {
            throw SSHTunnelError.connectionTimeout
        }
        return try handleResult(code)
    }

    private func showAlert() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Verification Code Required")
        alert.informativeText = String(
            localized: "Enter the TOTP verification code for SSH authentication."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "000000"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return textField.stringValue
        }
        return nil
    }

    private func handleResult(_ code: String?) throws -> String {
        guard let totpCode = code, !totpCode.isEmpty else {
            throw SSHTunnelError.authenticationFailed
        }
        return totpCode
    }
}
