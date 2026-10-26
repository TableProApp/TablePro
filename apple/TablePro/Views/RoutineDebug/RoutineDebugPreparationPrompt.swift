//
//  RoutineDebugPreparationPrompt.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// The plugin's preparation question (Oracle's compile for debug), answerable by the person or withdrawn by the run.
@MainActor
internal enum RoutineDebugPreparationPrompt {
    static func confirm(
        _ preparation: PluginDebugPreparation,
        window: NSWindow?,
        setup: RoutineDebugSetup
    ) async -> Bool {
        guard !setup.isCancelled else { return false }
        let alert = NSAlert()
        alert.messageText = preparation.message
        alert.informativeText = preparation.informativeText ?? ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: preparation.actionTitle)
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        setup.dismissPresentation = { withdraw(alert) }
        let response = await AlertHelper.response(to: alert, in: window)
        setup.dismissPresentation = nil
        return response == .alertFirstButtonReturn && !setup.isCancelled
    }

    // Answered as Cancel, so the presenter's completion runs and nothing waits on an alert nobody can see.
    private static func withdraw(_ alert: NSAlert) {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        } else if NSApp.modalWindow === alert.window {
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
    }
}
