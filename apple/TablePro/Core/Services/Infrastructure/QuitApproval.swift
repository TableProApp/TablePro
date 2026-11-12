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
        let transactions = openTransactionNames(
            holds: Array(DatabaseManager.shared.sessionTransactions.holds.values),
            connectionName: { DatabaseManager.shared.session(for: $0)?.connection.name }
        )
        let losses = (hasUnsavedTabs ? [String(localized: "Unsaved edits in open tabs")] : [])
            + RunningWorkPrompt.transactionLines(for: transactions)
        if let prompt = RunningWorkPrompt.make(action: action, work: work, otherLosses: losses) {
            guard RunningWorkApproval.confirmModally(prompt) else { return false }
            if stopsWork { registry.cancel(work) }
            return true
        }
        if let prompt = transactionPrompt(action: action, connections: transactions, hasUnsavedTabs: hasUnsavedTabs) {
            return RunningWorkApproval.confirmModally(prompt)
        }
        return !hasUnsavedTabs || approvesDiscardingUnsavedTabs()
    }

    // The server rolls back what a quit leaves open, so a hold is asked about like unsaved work.
    internal static func openTransactionNames(
        holds: [SessionTransactionTracker.Hold],
        connectionName: (UUID) -> String?
    ) -> [String] {
        var names: [String] = []
        for hold in holds {
            guard let name = connectionName(hold.connectionId), !names.contains(name) else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    internal static func transactionPrompt(
        action: RunningWorkAction,
        connections: [String],
        hasUnsavedTabs: Bool
    ) -> RunningWorkPrompt? {
        guard let first = connections.first else { return nil }
        let rolledBack = connections.count == 1
            ? String(format: String(localized: "Uncommitted changes on “%@” are rolled back when TablePro quits."), first)
            : String(
                format: String(localized: "Uncommitted changes on %@ are rolled back when TablePro quits."),
                ListFormatter.localizedString(byJoining: connections.map { "“\($0)”" })
            )
        let unsaved = String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
        let relaunches = action == .relaunch
        return RunningWorkPrompt(
            title: relaunches
                ? String(localized: "Relaunch with an Open Transaction?")
                : String(localized: "Quit with an Open Transaction?"),
            message: hasUnsavedTabs ? "\(rolledBack)\n\n\(unsaved)" : rolledBack,
            confirmButton: relaunches ? String(localized: "Relaunch Anyway") : String(localized: "Quit Anyway")
        )
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
