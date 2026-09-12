//
//  AlertHelper.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

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

    /// The window a sheet belongs on. A sheet the user is meant to read against their work must
    /// land on a document window, so a floating panel is never a candidate: the Quick Switcher
    /// closes the moment it loses focus, taking the sheet with it. An explicit window is honoured
    /// as given, and when nothing qualifies the caller runs the alert application-modal instead.
    static func resolveWindow(_ window: NSWindow?) -> NSWindow? {
        if let window { return window }
        if let candidate = [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }).first(where: isContentWindow) {
            return candidate
        }
        return NSApp.windows.first { $0.isVisible && isContentWindow($0) }
    }

    static func isContentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    /// The one presentation path for every alert in the app: a sheet on the window the user was
    /// working in, and an application-modal run only when no window qualifies. Each presenter used
    /// to spell this out for itself, which is how they drifted apart on which window they accepted.
    static func present(
        _ alert: NSAlert,
        in window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        guard let parent = resolveWindow(window) else {
            /// The two sibling detached-modal paths already come forward before they block, and this
            /// one did not. An alert nobody can see still holds a nested modal run loop, and a
            /// process serving MCP in the background has no window to click and no Dock icon to
            /// reach for, so the caller waits on an answer that can never be given.
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            AppActivationPolicyController.shared.reevaluate()
            completion(response)
            return
        }
        alert.beginSheetModal(for: parent, completionHandler: completion)
    }

    static func response(to alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            present(alert, in: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Confirmations

    /// A question whose confirming button keeps Return. `confirmDestructive` takes it off on
    /// purpose, which is right for destroying something and wrong for a step already asked for.
    static func confirm(
        title: String,
        message: String,
        confirmButton: String,
        cancelButton: String = String(localized: "Cancel"),
        window: NSWindow? = nil
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmButton)
        Self.addCancelButton(to: alert, title: cancelButton)
        return await response(to: alert, in: window) == .alertFirstButtonReturn
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
        return await response(to: alert, in: window) == .alertFirstButtonReturn
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
        return await response(to: alert, in: window) == .alertFirstButtonReturn
    }

    // MARK: - Cross-Process Approval

    static func runApprovalModal(
        title: String,
        message: String,
        confirm: String,
        cancel: String
    ) async -> Bool {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        let response = alert.runModal()
        AppActivationPolicyController.shared.reevaluate()
        return response == .alertFirstButtonReturn
    }

    /// Pairing is a security decision, so the attached case uses a critical sheet: it must not
    /// queue behind whatever sheet the window is already showing.
    static func runPairingApproval(request: PairingRequest) async throws -> PairingApproval {
        let codeExpiresAt = Date.now.addingTimeInterval(PairingExchangeStore.exchangeWindow)
        let gate = ModalDecisionGate<PairingApproval>.pairing()
        return try await runHostedDecision(
            title: String(localized: "Approve Integration"),
            fittingWidth: 520,
            gate: gate,
            window: nil,
            rootView: PairingApprovalSheet(
                request: request,
                codeExpiresAt: codeExpiresAt,
                onComplete: { result in gate.deliver(result) }
            )
        )
    }

    /// A statement the user has to read before approving it. The alert vocabulary cannot carry one:
    /// `informativeText` is a proportional label with no scrolling and no selection, so a statement
    /// long enough to be worth reviewing is exactly the one it cannot show.
    ///
    /// The windowless path is the ordinary case rather than a fallback. A request arriving over MCP
    /// reaches a Mac whose TablePro may have no window open at all, and that is precisely when this
    /// dialog is the only place the statement is visible.
    static func runStatementConfirmation(
        title: String,
        subtitle: String,
        warning: String?,
        statements: [String],
        databaseType: DatabaseType,
        confirmTitle: String,
        isDestructive: Bool,
        window: NSWindow?
    ) async -> Bool {
        let gate = ModalDecisionGate<Bool>.confirmation()
        let presented = Binding<Bool>(
            get: { true },
            set: { isPresented in
                guard !isPresented else { return }
                gate.deliver(.success(false))
            }
        )
        let sheet = SQLReviewSheet(
            isPresented: presented,
            statements: statements,
            databaseType: databaseType,
            title: title,
            subtitle: subtitle,
            showsStatementsVerbatim: true,
            warning: warning,
            primaryAction: SQLReviewSheet.PrimaryAction(
                title: confirmTitle,
                isDestructive: isDestructive,
                takesDefaultAction: false,
                work: .immediate { gate.deliver(.success(true)) }
            )
        )
        let confirmed = try? await runHostedDecision(
            title: title,
            fittingWidth: 560,
            gate: gate,
            window: window,
            rootView: sheet
        )
        return confirmed ?? false
    }

    /// The one presentation path for a SwiftUI decision the user must answer: a critical sheet on
    /// the window they were working in, and an application-modal window when none qualifies. The
    /// modal loop runs directly rather than inside a continuation-installing closure, which would
    /// block the main actor while the continuation is still being installed.
    private static func runHostedDecision<Value: Sendable>(
        title: String,
        fittingWidth: CGFloat,
        gate: ModalDecisionGate<Value>,
        window: NSWindow?,
        rootView: some View
    ) async throws -> Value {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        let fitted = host.sizeThatFits(in: NSSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = NSRect(origin: .zero, size: fitted)

        host.title = title
        let sheetWindow = ModalDecisionWindow(contentViewController: host)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.isReleasedWhenClosed = false
        /// The HIG gives Escape to Cancel on every alert and sheet, and a confirmation that came
        /// forward over the user's own work is exactly the one that has to stay dismissable.
        sheetWindow.onCancel = { [weak gate] in gate?.cancel() }

        let delegate = ModalDecisionWindowDelegate { [weak gate] in gate?.cancel() }
        gate.windowDelegate = delegate
        sheetWindow.delegate = delegate

        guard let parent = resolveWindow(window) else {
            gate.onResolve = { [weak sheetWindow] in
                NSApp.stopModal()
                sheetWindow?.close()
            }
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            sheetWindow.center()
            NSApp.runModal(for: sheetWindow)
            AppActivationPolicyController.shared.reevaluate(excluding: sheetWindow)
            return try gate.result()
        }

        gate.onResolve = { [weak sheetWindow] in
            guard let sheetWindow else { return }
            parent.endSheet(sheetWindow)
            sheetWindow.close()
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

        switch await response(to: alert, in: window) {
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

        switch await response(to: alert, in: window) {
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
        alert.informativeText = errorInformativeText(message: message, recoverySuggestion: recoverySuggestion)
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, in: window)
    }

    static func showRecoverableErrorSheet(
        title: String,
        message: String,
        recoverySuggestion: String?,
        recoveryTitle: String,
        window: NSWindow?,
        onRecover: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = errorInformativeText(message: message, recoverySuggestion: recoverySuggestion)
        alert.alertStyle = .warning
        alert.addButton(withTitle: recoveryTitle)
        addCancelButton(to: alert, title: String(localized: "Cancel"))
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onRecover()
        }
    }

    nonisolated static func errorInformativeText(message: String, recoverySuggestion: String?) -> String {
        let text = [message, recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return RevealedText(text).plainText
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
