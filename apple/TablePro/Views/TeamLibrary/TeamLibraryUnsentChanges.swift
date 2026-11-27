//
//  TeamLibraryUnsentChanges.swift
//  TablePro
//

import AppKit

// How Sign Out names the Team Library edits the team has not taken yet, and the notice when another account's sign-in
// deleted edits an earlier sign-in left on this Mac.
@MainActor
internal enum TeamLibraryUnsentChanges {
    nonisolated static func message(_ changes: [String], failure: TeamLibraryFailure?) -> String {
        var sentences: [String] = []
        if let failure {
            sentences.append(String(
                format: String(localized: "The upload did not finish. %@"),
                TeamLibraryPublishing.failureText(failure)
            ))
        }
        sentences.append(String(
            format: String(localized: "These changes are not uploaded yet and are lost if you discard them: %@."),
            changes.formatted(.list(type: .and))
        ))
        return sentences.joined(separator: " ")
    }

    // A refused edit as the unsent list names it.
    nonisolated static func refused(_ name: String, because reason: TeamLibraryFailure) -> String {
        let why: String
        switch reason {
        case .writeForbidden:
            why = String(localized: "only the team's owner, admins and editors publish")
        case .unreadable:
            why = String(localized: "no seat in the team")
        case .offline, .rateLimited, .server:
            why = String(localized: "the upload did not go through")
        default:
            why = String(localized: "the team library refused it")
        }
        return String(format: String(localized: "%@ (not sent: %@)"), name, why)
    }

    nonisolated static func conflicted(_ name: String) -> String {
        String(format: String(localized: "%@ (not sent: changed on the team since)"), name)
    }

    static func presentDiscarded(_ changes: [String]) {
        notify(
            title: String(localized: "Team Library changes were discarded"),
            message: String(
                format: String(localized: "Team Library ended for this sign-in before these changes were uploaded: %@."),
                changes.formatted(.list(type: .and))
            )
        )
    }

    // Never waits on the person: a sheet on the window in front, or on the first one to come up.
    private static func notify(title: String, message: String) {
        Task { @MainActor in
            if AlertHelper.resolveWindow(nil) == nil {
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeMainNotification) {
                    if AlertHelper.resolveWindow(nil) != nil { break }
                }
            }
            guard let window = AlertHelper.resolveWindow(nil) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}
