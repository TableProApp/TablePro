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
        _ = AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
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

    nonisolated static func conflicted(_ name: String) -> String {
        String(format: String(localized: "%@ (not sent: changed on the team since)"), name)
    }

    // An involuntary sign-out, or a lost team_library, leaves no one to push for, so its unsent edits go and the person
    // is told which.
    static func presentDiscarded(_ changes: [String]) {
        notify(
            title: String(localized: "Team Library changes were discarded"),
            message: String(
                format: String(localized: "Team Library ended for this sign-in before these changes were uploaded: %@."),
                changes.formatted(.list(type: .and))
            )
        )
    }

    static func presentEarlierEditsNotTaken(_ changes: [String]) {
        notify(
            title: String(localized: "Some Team Library changes from before the update were not uploaded"),
            message: String(
                format: String(localized: "TablePro uploaded the changes left from before the update once. These were not taken and were dropped: %@."),
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
