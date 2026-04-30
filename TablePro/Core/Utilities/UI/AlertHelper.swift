//
//  AlertHelper.swift
//  TablePro
//
//  Created by TablePro on 1/19/26.
//

import AppKit
import SwiftUI

/// Centralized helper for creating and displaying NSAlert dialogs
/// Provides consistent styling and behavior across the application
@MainActor
final class AlertHelper {
    /// Tries multiple sources to find a presentable window, minimizing runModal() fallback usage.
    static func resolveWindow(_ window: NSWindow?) -> NSWindow? {
        window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    // MARK: - Destructive Confirmations

    /// Shows a destructive confirmation dialog (warning style)
    /// Uses async sheet presentation when window is available, falls back to modal
    /// - Parameters:
    ///   - title: Alert title
    ///   - message: Detailed message
    ///   - confirmButton: Label for destructive action button (default: "OK")
    ///   - cancelButton: Label for cancel button (default: "Cancel")
    ///   - window: Parent window to attach sheet to (optional)
    /// - Returns: true if user confirmed, false if cancelled
    static func confirmDestructive(
        title: String,
        message: String,
        confirmButton: String = String(localized: "OK"),
        cancelButton: String = String(localized: "Cancel"),
        window: NSWindow? = nil
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: cancelButton)

        // Use sheet presentation when window is available (non-blocking, Swift 6 friendly)
        if let window = resolveWindow(window) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        } else {
            // Fallback to modal when no window available
            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }

    // MARK: - Critical Confirmations

    /// Shows a critical confirmation dialog (critical style)
    /// Uses async sheet presentation when window is available, falls back to modal
    /// Used for dangerous operations like DROP, TRUNCATE, DELETE without WHERE
    /// - Parameters:
    ///   - title: Alert title
    ///   - message: Detailed message
    ///   - confirmButton: Label for dangerous action button (default: "Execute")
    ///   - cancelButton: Label for cancel button (default: "Cancel")
    ///   - window: Parent window to attach sheet to (optional)
    /// - Returns: true if user confirmed, false if cancelled
    static func confirmCritical(
        title: String,
        message: String,
        confirmButton: String = String(localized: "Execute"),
        cancelButton: String = String(localized: "Cancel"),
        window: NSWindow? = nil
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: cancelButton)

        // Use sheet presentation when window is available (non-blocking, Swift 6 friendly)
        if let window = resolveWindow(window) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        } else {
            // Fallback to modal when no window available
            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }

    // MARK: - Cross-Process Approval

    /// Shows an app-modal approval dialog for prompts originating from another process
    /// (Raycast, MCP clients, deeplink handlers). `runModal()` self-activates and blocks
    /// until the user responds, which is the correct pattern when no parent window exists.
    static func runApprovalModal(
        title: String,
        message: String,
        confirm: String,
        cancel: String
    ) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Presents the pairing approval sheet for an external integration request.
    /// Hosts `PairingApprovalSheet` in an `NSHostingController`. When a parent window
    /// exists the sheet attaches to it, otherwise it opens as a standalone window.
    static func runPairingApproval(request: PairingRequest) async throws -> PairingApproval {
        try await withCheckedThrowingContinuation { continuation in
            var deliver: ((Result<PairingApproval, Error>) -> Void)?
            let host = NSHostingController(
                rootView: PairingApprovalSheet(
                    request: request,
                    onComplete: { result in deliver?(result) }
                )
            )
            host.view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)

            let parent = resolveWindow(nil)
            let sheetWindow = NSWindow(contentViewController: host)
            sheetWindow.styleMask = [.titled]
            sheetWindow.title = String(localized: "Approve Integration")
            sheetWindow.isReleasedWhenClosed = false

            var resolved = false
            deliver = { result in
                guard !resolved else { return }
                resolved = true
                if let parent {
                    parent.endSheet(sheetWindow)
                } else {
                    sheetWindow.close()
                }
                continuation.resume(with: result)
            }

            if let parent {
                parent.beginSheet(sheetWindow, completionHandler: nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                sheetWindow.center()
                sheetWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Save Changes Confirmation

    /// Result of a standard macOS save-changes confirmation dialog
    enum SaveConfirmationResult {
        case save, dontSave, cancel
    }

    /// Shows the standard macOS "save changes before closing?" dialog.
    /// Button layout matches NSDocument convention: Save (default) | Cancel | Don't Save (Cmd+D).
    /// - Parameters:
    ///   - message: Detailed message explaining what has unsaved changes
    ///   - window: Parent window to attach sheet to (optional)
    /// - Returns: The user's choice
    static func confirmSaveChanges(
        message: String,
        window: NSWindow? = nil
    ) async -> SaveConfirmationResult {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save changes?")
        alert.informativeText = message
        alert.alertStyle = .warning

        // Button order follows macOS convention (rightmost → leftmost):
        // [Don't Save]  [Cancel]  [Save]
        alert.addButton(withTitle: String(localized: "Save"))       // alertFirstButtonReturn (default)
        alert.addButton(withTitle: String(localized: "Cancel"))     // alertSecondButtonReturn
        let dontSaveButton = alert.addButton(withTitle: String(localized: "Don't Save")) // alertThirdButtonReturn
        dontSaveButton.hasDestructiveAction = true
        dontSaveButton.keyEquivalent = "d"
        dontSaveButton.keyEquivalentModifierMask = .command

        let response: NSApplication.ModalResponse

        if let window = resolveWindow(window) {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { resp in
                    continuation.resume(returning: resp)
                }
            }
        } else {
            response = alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    // MARK: - Three-Way Confirmations

    /// Shows a three-option confirmation dialog
    /// Uses async sheet presentation when window is available, falls back to modal
    /// - Parameters:
    ///   - title: Alert title
    ///   - message: Detailed message
    ///   - first: Label for first button
    ///   - second: Label for second button
    ///   - third: Label for third button
    ///   - window: Parent window to attach sheet to (optional)
    /// - Returns: 0 for first button, 1 for second, 2 for third
    static func confirmThreeWay(
        title: String,
        message: String,
        first: String,
        second: String,
        third: String,
        window: NSWindow? = nil
    ) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: first)
        alert.addButton(withTitle: second)
        alert.addButton(withTitle: third)

        let response: NSApplication.ModalResponse

        // Use sheet presentation when window is available (non-blocking, Swift 6 friendly)
        if let window = resolveWindow(window) {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { resp in
                    continuation.resume(returning: resp)
                }
            }
        } else {
            // Fallback to modal when no window available
            response = alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn:
            return 0
        case .alertSecondButtonReturn:
            return 1
        case .alertThirdButtonReturn:
            return 2
        default:
            return 2 // Default to third option (usually cancel)
        }
    }

    // MARK: - Error Sheets

    /// Shows an error message as a non-blocking sheet
    /// - Parameters:
    ///   - title: Error title
    ///   - message: Error details
    ///   - window: Parent window to attach sheet to (optional, falls back to modal)
    static func showErrorSheet(
        title: String,
        message: String,
        window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK"))

        if let window = resolveWindow(window) {
            alert.beginSheetModal(for: window) { _ in
                // Sheet dismissed, no action needed
            }
        } else {
            // Fallback to modal if no window available
            alert.runModal()
        }
    }

    // MARK: - Info Sheets

    /// Shows an informational message as a non-blocking sheet
    /// - Parameters:
    ///   - title: Info title
    ///   - message: Info details
    ///   - window: Parent window to attach sheet to (optional, falls back to modal)
    static func showInfoSheet(
        title: String,
        message: String,
        window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))

        if let window = resolveWindow(window) {
            alert.beginSheetModal(for: window) { _ in
                // Sheet dismissed, no action needed
            }
        } else {
            // Fallback to modal if no window available
            alert.runModal()
        }
    }

    // MARK: - Query Error with AI Option

    /// Shows a query error dialog with an option to ask AI to fix it
    /// - Parameters:
    ///   - title: Error title
    ///   - message: Error details
    ///   - window: Parent window to attach sheet to (optional)
    /// - Returns: true if "Ask AI to Fix" was clicked
    static func showQueryErrorWithAIOption(
        title: String,
        message: String,
        window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Ask AI to Fix"))

        if let window = resolveWindow(window) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertSecondButtonReturn)
                }
            }
        } else {
            let response = alert.runModal()
            return response == .alertSecondButtonReturn
        }
    }
}
