//
//  AccountSignOutPrompt.swift
//  TablePro
//

import AppKit

internal enum AccountSignOutAnswer: Equatable {
    case upload
    case discard
    case cancel
}

// Sign Out's question, on the window in front or on its own: the flow that asks owns it, not the Settings window.
@MainActor
internal enum AccountSignOutPrompt {
    private static var open: NSAlert?

    static func ask(_ confirmation: AccountSignOutConfirmation) async -> AccountSignOutAnswer {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out of TablePro on this Mac?")
        alert.informativeText = confirmation.message
        let answers: [AccountSignOutAnswer]
        if confirmation.teamChanges.isEmpty {
            alert.addButton(withTitle: String(localized: "Sign Out")).hasDestructiveAction = confirmation.discardsSomething
            answers = [.discard]
        } else {
            alert.addButton(withTitle: String(localized: "Upload and Sign Out"))
            alert.addButton(withTitle: String(localized: "Discard and Sign Out")).hasDestructiveAction = true
            answers = [.upload, .discard]
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        open = alert
        defer { open = nil }
        let response = await AlertHelper.response(to: alert, in: nil)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) ? answers[index] : .cancel
    }

    // Signed out another way while it asks: there is nothing left to answer.
    static func close() {
        guard let alert = open else { return }
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else {
            NSApp.stopModal(withCode: .cancel)
        }
    }
}
