import AppKit

/// Everything that can still stop a quit, asked from `applicationShouldTerminate`. The termination
/// notification comes after AppKit is told yes, too late for any of these to cancel it.
@MainActor
internal enum QuitApproval {
    internal static func approve() -> Bool {
        guard approvesStoppingSync() else { return false }
        guard ThemeEditorWindows.shared.prepareToTerminate() else { return false }
        return approvesDiscardingUnsavedTabs()
    }

    private static func approvesStoppingSync() -> Bool {
        guard CompareSyncRunRegistry.shared.isApplying else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "A sync is still running")
        alert.informativeText = String(
            format: String(localized: "Quitting stops the run against %@. Statements that already ran stay applied."),
            CompareSyncRunRegistry.shared.applyingTargetNames.joined(separator: ", ")
        )
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Stop and Quit"))
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func approvesDiscardingUnsavedTabs() -> Bool {
        guard MainContentCoordinator.hasAnyUnsavedChanges() else { return true }
        // Quitting can be asked for from outside the app, so this alert has to come forward on its
        // own: it blocks termination in a nested modal loop, and a background process has no Dock
        // icon to reach it by.
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes")
        alert.informativeText = String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
