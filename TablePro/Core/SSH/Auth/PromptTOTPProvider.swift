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
    func provideCode(attempt: Int) throws -> String {
        if Thread.isMainThread {
            return try handleResult(showAlert(attempt: attempt))
        }
        return try handleResult(DispatchQueue.main.sync { showAlert(attempt: attempt) })
    }

    // Note: runModal() is intentional here. This method runs on the main thread
    // (via DispatchQueue.main.sync from provideCode), so beginSheetModal + semaphore would deadlock.
    private func showAlert(attempt: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = attempt == 0
            ? String(localized: "Verification Code Required")
            : String(localized: "Verification Code Rejected")
        alert.informativeText = attempt == 0
            ? String(localized: "Enter the TOTP verification code for SSH authentication.")
            : String(localized: "The previous code wasn't accepted. Wait for your authenticator to refresh, then enter the new code.")
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
            throw SSHTunnelError.authenticationFailed(reason: .verificationCode)
        }
        return totpCode
    }
}
