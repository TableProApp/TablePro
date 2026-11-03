//
//  RunningWorkApproval.swift
//  TablePro
//

import AppKit

@MainActor
internal enum RunningWorkApproval {
    // Quit asks from applicationShouldTerminate, which needs its answer before it returns.
    internal static func confirmModally(_ prompt: RunningWorkPrompt) -> Bool {
        // A quit can come from outside the app, and a background process has no Dock icon to reach the alert by.
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return makeAlert(prompt).runModal() == .alertFirstButtonReturn
    }

    // On the window's frontmost sheet: a progress sheet for the very work being asked about would hold the alert back.
    internal static func confirm(_ prompt: RunningWorkPrompt, window: NSWindow?) async -> Bool {
        let parent = AlertHelper.resolveWindow(window).map(AlertOperationConfirming.frontmostSheet(of:))
        return await AlertHelper.response(to: makeAlert(prompt), in: parent) == .alertFirstButtonReturn
    }

    private static func makeAlert(_ prompt: RunningWorkPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: prompt.confirmButton,
            cancelButton: String(localized: "Cancel")
        )
        return alert
    }
}
