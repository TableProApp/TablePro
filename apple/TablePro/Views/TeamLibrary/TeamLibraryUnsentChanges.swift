//
//  TeamLibraryUnsentChanges.swift
//  TablePro
//

import AppKit

// What happens to Team Library edits not uploaded yet, which live only in memory (I1, I4 and I5 on TeamLibrarySync).
@MainActor
internal enum TeamLibraryUnsentChanges {
    enum Choice: Equatable {
        case upload
        case discard
        case cancel
    }

    // The quit's question, then the rest of the quit with Team Library held. A Cancel here or a later step that stops
    // the quit releases the hold, so the app that stays open syncs again. Discard drops the edits only once the quit
    // is committed, in applicationWillTerminate, so a quit that stops later keeps them.
    static func quit(
        _ sync: TeamLibrarySync = .shared,
        ask: @MainActor ([String], TeamLibraryFailure?) async -> Choice = askBeforeQuitting,
        then rest: @MainActor () async -> Bool
    ) async -> Bool {
        let hold = await sync.hold()
        var quits = false
        defer {
            if !quits {
                hold.release()
            }
        }
        var changes = sync.unsentChanges
        var failure: TeamLibraryFailure?
        while !changes.isEmpty {
            switch await ask(changes, failure) {
            case .upload:
                (changes, failure) = await sync.pushHeld()
            case .discard:
                changes = []
            case .cancel:
                return false
            }
        }
        quits = await rest()
        return quits
    }

    static func askBeforeQuitting(_ changes: [String], failure: TeamLibraryFailure?) async -> Choice {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Upload Team Library changes before quitting?")
        alert.informativeText = message(changes, failure: failure)
        alert.addButton(withTitle: String(localized: "Upload and Quit"))
        let discard = alert.addButton(withTitle: String(localized: "Discard and Quit"))
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch await AlertHelper.response(to: alert, in: nil) {
        case .alertFirstButtonReturn: return .upload
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

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

    // True uploads them now, false discards them.
    static func uploadsEarlierEdits(_ changes: [String]) async -> Bool {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Upload Team Library changes from before the update?")
        alert.informativeText = String(
            format: String(localized: "Not uploaded before TablePro updated: %@. They are not kept on disk any more, so TablePro asks once."),
            changes.formatted(.list(type: .and))
        )
        alert.addButton(withTitle: String(localized: "Upload"))
        let discard = alert.addButton(withTitle: String(localized: "Discard"))
        discard.hasDestructiveAction = true
        return await AlertHelper.response(to: alert, in: nil) == .alertFirstButtonReturn
    }

    // A refused edit as the unsent list names it.
    nonisolated static func refused(_ name: String, because reason: TeamLibraryFailure) -> String {
        let why: String
        switch reason {
        case .writeForbidden:
            why = String(localized: "only the team's owner and admins publish")
        case .unreadable:
            why = String(localized: "no seat in the team")
        case .offline, .rateLimited, .server:
            why = String(localized: "the upload did not go through")
        default:
            why = String(localized: "the team library refused it")
        }
        return String(format: String(localized: "%@ (not sent: %@)"), name, why)
    }

    // An involuntary sign-out leaves no one to push for, so its unsent edits go and the person is told which.
    static func presentDiscarded(_ changes: [String]) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Team Library changes were discarded"),
            message: String(
                format: String(localized: "You were signed out before these changes were uploaded: %@."),
                changes.formatted(.list(type: .and))
            ),
            window: nil
        )
    }
}
