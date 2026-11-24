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

    // The quit's question. False is Cancel: the app stays open and Team Library syncs on.
    static func approveQuit(
        _ sync: TeamLibrarySync = .shared,
        ask: @MainActor ([String], TeamLibraryFailure?) async -> Choice = askBeforeQuitting
    ) async -> Bool {
        var changes = await sync.hold()
        var failure: TeamLibraryFailure?
        while !changes.isEmpty {
            switch await ask(changes, failure) {
            case .upload:
                (changes, failure) = await sync.pushHeld()
            case .discard:
                sync.discardHeld()
                return true
            case .cancel:
                sync.release()
                return false
            }
        }
        return true
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
