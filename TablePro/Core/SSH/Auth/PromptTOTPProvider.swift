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
        return try handleResult(DispatchQueue.main.sync { showAlert() })
    }

    // Note: runModal() is intentional here. This method runs on the main thread
    // (via DispatchQueue.main.sync from provideCode), so beginSheetModal + semaphore would deadlock.
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
        return response == .alertFirstButtonReturn ? textField.stringValue : nil
    }

    private func handleResult(_ code: String?) throws -> String {
        guard let totpCode = code, !totpCode.isEmpty else {
            throw SSHTunnelError.authenticationFailed
        }
        return totpCode
    }
}
