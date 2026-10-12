//
//  AlertHelper+Consent.swift
//  TablePro
//

import AppKit

internal enum ConsentAnswer: Sendable, Equatable {
    case approved
    case declined
    case unanswered
}

extension AlertHelper {
    /// A consent prompt can be waited on by an MCP client or a script on a Mac nobody is at, so it
    /// closes on its own rather than holding that caller for as long as it stays up.
    static let consentAnswerWindow: TimeInterval = 60

    /// Escape cancels and Return does nothing, so approving running code takes a deliberate click.
    static func askConsent(
        title: String,
        message: String,
        confirmButton: String,
        window: NSWindow?
    ) async -> ConsentAnswer {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        addConfirmAndCancel(to: alert, confirmButton: confirmButton, cancelButton: String(localized: "Cancel"))
        switch await response(to: alert, in: window, answerWithin: consentAnswerWindow) {
        case .alertFirstButtonReturn:
            return .approved
        case .abort:
            return .unanswered
        default:
            return .declined
        }
    }

    /// The alert reports `.abort` once `limit` passes without an answer. A run loop timer does the
    /// withdrawing because no main-actor task runs while `runModal` holds the main queue, and it
    /// repeats until the withdrawal lands, since a sheet queued behind another has no parent yet.
    static func response(
        to alert: NSAlert,
        in window: NSWindow?,
        answerWithin limit: TimeInterval
    ) async -> NSApplication.ModalResponse {
        let timer = Timer(fire: Date.now.addingTimeInterval(limit), interval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { withdraw(alert) }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        return await response(to: alert, in: window)
    }

    private static func withdraw(_ alert: NSAlert) {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
            return
        }
        guard NSApp.modalWindow === alert.window else { return }
        /// A stop asked for outside the modal loop's own event handling takes effect on the next
        /// event, so one is posted.
        NSApp.stopModal(withCode: .abort)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApp.postEvent(wake, atStart: true)
        }
    }
}
