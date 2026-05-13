//
//  AlertHelper.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class AlertHelper {
    static func resolveWindow(_ window: NSWindow?) -> NSWindow? {
        window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    // MARK: - Destructive Confirmations

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

        if let window = resolveWindow(window) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Critical Confirmations

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

        if let window = resolveWindow(window) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Cross-Process Approval

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

    static func runPairingApproval(request: PairingRequest) async throws -> PairingApproval {
        try await withCheckedThrowingContinuation { continuation in
            var deliver: ((Result<PairingApproval, Error>) -> Void)?
            let codeExpiresAt = Date.now.addingTimeInterval(PairingExchangeStore.exchangeWindow)
            let host = NSHostingController(
                rootView: PairingApprovalSheet(
                    request: request,
                    codeExpiresAt: codeExpiresAt,
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

    enum SaveConfirmationResult {
        case save, dontSave, cancel
    }

    static func confirmSaveChanges(
        message: String,
        window: NSWindow? = nil
    ) async -> SaveConfirmationResult {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save changes?")
        alert.informativeText = message
        alert.alertStyle = .warning

        // Button order follows NSDocument convention: Save | Cancel | Don't Save (Cmd+D)
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let dontSaveButton = alert.addButton(withTitle: String(localized: "Don't Save"))
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
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    // MARK: - Three-Way Confirmations

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
        case .alertFirstButtonReturn: return 0
        case .alertSecondButtonReturn: return 1
        case .alertThirdButtonReturn: return 2
        default: return 2
        }
    }

    // MARK: - Error / Info Sheets

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
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

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
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    // MARK: - Query Error with AI Option

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
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
