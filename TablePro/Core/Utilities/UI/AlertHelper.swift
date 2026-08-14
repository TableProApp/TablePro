//
//  AlertHelper.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class AlertHelper {
    /// An `NSButton` holds exactly one key equivalent, so moving Return onto Cancel overwrites the
    /// Escape that `NSAlert` puts there and leaves the alert with no way out from the keyboard.
    /// Return is taken off the confirming button instead and handed to nobody, which is the shape
    /// macOS itself ships for a destructive alert: Escape cancels, and destroying takes a
    /// deliberate click.
    ///
    /// `hasDestructiveAction` alone reaches the same state, but only once the alert lays out, so
    /// the binding is written here as well to make it true from the moment the alert is built.
    static func addConfirmAndCancel(
        to alert: NSAlert,
        confirmButton: String,
        cancelButton: String
    ) {
        let confirm = alert.addButton(withTitle: confirmButton)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        addCancelButton(to: alert, title: cancelButton)
    }

    /// `NSAlert` only recognises a cancel button by its title, which stops matching the moment the
    /// title is localized, so the binding is made explicit rather than inferred.
    @discardableResult
    static func addCancelButton(to alert: NSAlert, title: String) -> NSButton {
        let cancel = alert.addButton(withTitle: title)
        cancel.keyEquivalent = "\u{1B}"
        return cancel
    }

    static func resolveWindow(_ window: NSWindow?) -> NSWindow? {
        window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    /// A sheet the user is meant to read against their work must land on a document window.
    /// `resolveWindow`'s last resort accepts any visible window, which includes floating panels
    /// such as the Quick Switcher, so a file error can end up attached to a panel that closes
    /// the moment it loses focus.
    static func resolveContentWindow(_ window: NSWindow?) -> NSWindow? {
        if let window { return window }
        if let candidate = [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }).first(where: isContentWindow) {
            return candidate
        }
        return NSApp.windows.first { $0.isVisible && isContentWindow($0) }
    }

    static func isContentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    /// An alert belongs to the window the user was working in, so it runs as a sheet whenever one
    /// can be resolved and falls back to an application-modal run only when none can.
    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let parent = resolveWindow(window) else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
    }

    /// For the alerts whose only button is an acknowledgement, where nothing waits on the answer.
    private static func present(_ alert: NSAlert, in window: NSWindow?) {
        guard let parent = resolveWindow(window) else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: parent) { _ in }
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
        Self.addConfirmAndCancel(to: alert, confirmButton: confirmButton, cancelButton: cancelButton)
        return await run(alert, in: window) == .alertFirstButtonReturn
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
        Self.addConfirmAndCancel(to: alert, confirmButton: confirmButton, cancelButton: cancelButton)
        return await run(alert, in: window) == .alertFirstButtonReturn
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

    /// Pairing is a security decision, so the attached case uses a critical sheet: it must not
    /// queue behind whatever sheet the window is already showing. The detached case runs the modal
    /// loop directly rather than inside a continuation-installing closure, which would block the
    /// main actor while the continuation is still being installed.
    static func runPairingApproval(request: PairingRequest) async throws -> PairingApproval {
        let codeExpiresAt = Date.now.addingTimeInterval(PairingExchangeStore.exchangeWindow)
        let gate = PairingApprovalGate()
        let host = NSHostingController(
            rootView: PairingApprovalSheet(
                request: request,
                codeExpiresAt: codeExpiresAt,
                onComplete: { result in gate.deliver(result) }
            )
        )
        host.sizingOptions = []
        let fitted = host.sizeThatFits(in: NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = NSRect(origin: .zero, size: fitted)

        let sheetWindow = NSWindow(contentViewController: host)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = String(localized: "Approve Integration")
        sheetWindow.isReleasedWhenClosed = false

        guard let parent = resolveContentWindow(nil) else {
            let delegate = PairingApprovalWindowDelegate(gate: gate)
            sheetWindow.delegate = delegate
            gate.onResolve = { [weak sheetWindow] in
                NSApp.stopModal()
                sheetWindow?.close()
            }
            NSApp.activate(ignoringOtherApps: true)
            sheetWindow.center()
            defer { withExtendedLifetime(delegate) {} }
            NSApp.runModal(for: sheetWindow)
            return try gate.result()
        }

        gate.onResolve = { [weak sheetWindow] in
            guard let sheetWindow else { return }
            parent.endSheet(sheetWindow)
        }
        parent.beginCriticalSheet(sheetWindow, completionHandler: nil)
        return try await gate.value()
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

        /// `NSDocument`'s own order: Save, Cancel, then Don't Save on Cmd+D.
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let dontSaveButton = alert.addButton(withTitle: String(localized: "Don't Save"))
        dontSaveButton.hasDestructiveAction = true
        dontSaveButton.keyEquivalent = "d"
        dontSaveButton.keyEquivalentModifierMask = .command

        switch await run(alert, in: window) {
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

        switch await run(alert, in: window) {
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
        recoverySuggestion: String? = nil,
        window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = [message, recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, in: window)
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
        present(alert, in: window)
    }
}
