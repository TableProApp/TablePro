import AppKit

// The termination notification comes after AppKit is told yes, too late to cancel a quit.
@MainActor
internal enum QuitApproval {
    internal static func approve(
        registry: RunningWorkRegistry = .shared,
        relaunchApproved: Bool = AppRelauncher.shared.hasApprovedRunningWork
    ) -> Bool {
        // A relaunch asked both questions before it quit; the work it approved stopping stops now.
        guard !relaunchApproved else {
            registry.cancel(registry.items(in: .app))
            return true
        }
        // The theme editor can still cancel, so it asks before any work is stopped.
        guard ThemeEditorWindows.shared.prepareToTerminate() else { return false }
        return approvesStoppingWork(registry: registry, action: .quit)
    }

    // One alert for what a quit or relaunch loses. Running work lists the unsaved tabs with it.
    internal static func approvesStoppingWork(
        registry: RunningWorkRegistry,
        action: RunningWorkAction,
        stopsWork: Bool = true
    ) -> Bool {
        // A large document's last keys reach its tab on a delay; without them a dirty file reads as clean.
        EditorEventRouter.shared.flushAllPendingText()
        let work = registry.items(in: .app)
        let hasUnsavedTabs = MainContentCoordinator.hasAnyUnsavedChanges()
        let losses = hasUnsavedTabs ? [String(localized: "Unsaved edits in open tabs")] : []
        if let prompt = RunningWorkPrompt.make(action: action, work: work, otherLosses: losses) {
            guard RunningWorkApproval.confirmModally(prompt) else { return false }
            if stopsWork { registry.cancel(work) }
            return true
        }
        return !hasUnsavedTabs || approvesDiscardingUnsavedTabs()
    }

    private static func approvesDiscardingUnsavedTabs() -> Bool {
        // A quit can come from outside the app, and a background process has no Dock icon to reach the alert by.
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
