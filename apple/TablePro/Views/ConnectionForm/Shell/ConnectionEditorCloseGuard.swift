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
    static func verdict(
        hasUnsavedChanges: Bool,
        isRecordMissing: Bool,
        connectionName: String,
        blockingIssue: String? = nil
    ) -> Verdict {
        guard hasUnsavedChanges, !isRecordMissing else { return .close }
        return .askToSave(ConnectionEditorSavePrompt(connectionName: connectionName, blockingIssue: blockingIssue))
    }

    // The order of `makeAlert`: Save, Cancel, Don't Save; or Cancel, Don't Save when Save is blocked.
    static func choice(for response: NSApplication.ModalResponse, canSave: Bool = true) -> Choice {
        switch (response, canSave) {
        case (.alertFirstButtonReturn, true): return .save
        case (.alertThirdButtonReturn, true), (.alertSecondButtonReturn, false): return .dontSave
        default: return .cancel
        }
    }

    // An alert offers no button that cannot do what it says: with Save blocked it names why and offers Don't Save
    // and Cancel, and Return picks neither, since the only other answer discards.
    @MainActor
    static func makeAlert(_ prompt: ConnectionEditorSavePrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        if prompt.canSave {
            alert.addButton(withTitle: String(localized: "Save"))
            AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        } else {
            AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        }
        let dontSave = alert.addButton(withTitle: String(localized: "Don't Save"))
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        return alert
    }
}

struct ConnectionEditorSavePrompt: Equatable {
    let connectionName: String
    var blockingIssue: String?

    var canSave: Bool { blockingIssue == nil }

    var title: String {
        guard canSave else {
            return String(format: String(localized: "The changes to “%@” can't be saved yet."), connectionName)
        }
        return String(format: String(localized: "Do you want to save the changes to “%@”?"), connectionName)
    }

    var message: String {
        let consequence = String(localized: "Your changes will be lost if you don't save them.")
        guard let blockingIssue else { return consequence }
        return "\(blockingIssue)\n\n\(consequence)"
    }
}

enum ConnectionEditorEscape {
    private static let escapeKeyCode: UInt16 = 53

    // Escape while a text field or a code editor is being edited; a sheet answers its own.
    @MainActor
    static func endsEditing(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, event.keyCode == escapeKeyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
              event.windowNumber == window.windowNumber,
              window.attachedSheet == nil
        else { return false }
        return window.firstResponder is NSTextView
    }
}
