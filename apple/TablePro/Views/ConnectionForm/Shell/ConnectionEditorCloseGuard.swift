//
//  ConnectionEditorCloseGuard.swift
//  TablePro
//

import AppKit

// The close button, Cmd+W, Cancel and Escape all ask this before the window closes.
enum ConnectionEditorCloseGuard {
    enum Verdict: Equatable {
        case close
        case askToSave(ConnectionEditorSavePrompt)
    }

    enum Choice: Equatable {
        case save
        case dontSave
        case cancel
    }

    // A record deleted elsewhere cannot be saved, so there is nothing to ask.
    static func verdict(hasUnsavedChanges: Bool, isRecordMissing: Bool, connectionName: String) -> Verdict {
        guard hasUnsavedChanges, !isRecordMissing else { return .close }
        return .askToSave(ConnectionEditorSavePrompt(connectionName: connectionName))
    }

    // The order of `makeAlert`: Save, Cancel, Don't Save.
    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    @MainActor
    static func makeAlert(_ prompt: ConnectionEditorSavePrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don't Save"))
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        return alert
    }
}

struct ConnectionEditorSavePrompt: Equatable {
    let connectionName: String

    var title: String {
        String(format: String(localized: "Do you want to save the changes to “%@”?"), connectionName)
    }

    var message: String {
        String(localized: "Your changes will be lost if you don't save them.")
    }
}
