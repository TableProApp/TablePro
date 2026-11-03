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

    internal static func confirm(_ prompt: RunningWorkPrompt, window: NSWindow?) async -> Bool {
        await AlertHelper.response(to: makeAlert(prompt), in: window) == .alertFirstButtonReturn
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
