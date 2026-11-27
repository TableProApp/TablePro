import AppKit

// What an approved quit or relaunch does before it goes ahead.
internal struct QuitPlan {
    // Empty when nothing holds a transaction or the answer was Roll Back.
    internal let commits: [SessionTransactionTracker.Hold]
    // Stopped only once the commits landed, so a failed commit leaves it running.
    internal let work: [RunningWork]
}

// The termination notification comes after AppKit is told yes, too late to cancel a quit.
@MainActor
internal enum QuitApproval {
    internal static func approve(
        registry: RunningWorkRegistry = .shared,
        relaunchApproved: Bool = AppRelauncher.shared.hasApprovedRunningWork
    ) -> QuitPlan? {
        // A relaunch asked every question and committed before it quit; the work it approved stopping stops now.
        guard !relaunchApproved else {
            return QuitPlan(commits: [], work: registry.items(in: .app))
        }
        // The theme editor can still cancel, so it asks before anything else.
        guard ThemeEditorWindows.shared.prepareToTerminate() else { return nil }
        return approvesStoppingWork(registry: registry, action: .quit)
    }

    // Running work, then the open transactions, then unsaved tabs when no alert named them. Nil when any answer was Cancel.
    internal static func approvesStoppingWork(
        registry: RunningWorkRegistry,
        action: RunningWorkAction,
        databaseManager: DatabaseManager = .shared,
        hasUnsavedTabs: @MainActor () -> Bool = { MainContentCoordinator.hasAnyUnsavedChanges() },
        confirmWork: @MainActor (RunningWorkPrompt) -> Bool = RunningWorkApproval.confirmModally,
        answerTransaction: @MainActor (TransactionEndPrompt) -> AlertHelper.TransactionEndAnswer
            = QuitApproval.answerTransactionModally,
        confirmDiscardingTabs: @MainActor (RunningWorkAction) -> Bool = QuitApproval.approvesDiscardingUnsavedTabs
    ) -> QuitPlan? {
        // A large document's last keys reach its tab on a delay; without them a dirty file reads as clean.
        EditorEventRouter.shared.flushAllPendingText()
        let work = registry.items(in: .app)
        let unsavedTabs = hasUnsavedTabs()
        var namedUnsavedTabs = false
        if let prompt = RunningWorkPrompt.make(
            action: action,
            work: work,
            otherLosses: unsavedTabs ? [String(localized: "Unsaved edits in open tabs")] : []
        ) {
            guard confirmWork(prompt) else { return nil }
            namedUnsavedTabs = unsavedTabs
        }
        let holds = databaseManager.sessionTransactions.holds.values.sorted { lhs, rhs in
            (lhs.connectionId.uuidString, lhs.key.lane ?? "") < (rhs.connectionId.uuidString, rhs.key.lane ?? "")
        }
        var commits: [SessionTransactionTracker.Hold] = []
        if let prompt = transactionPrompt(
            action: action,
            holds: holds,
            hasUnsavedTabs: unsavedTabs && !namedUnsavedTabs,
            databaseManager: databaseManager
        ) {
            switch answerTransaction(prompt) {
            case .cancel:
                return nil
            case .rollBack:
                break
            case .commit:
                commits = holds
            }
            namedUnsavedTabs = unsavedTabs
        }
        guard !unsavedTabs || namedUnsavedTabs || confirmDiscardingTabs(action) else { return nil }
        return QuitPlan(commits: commits, work: work)
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

    // Tracker holds only, so every connection the prompt names has holds to commit through.
    internal static func transactionPrompt(
        action: RunningWorkAction,
        holds: [SessionTransactionTracker.Hold],
        hasUnsavedTabs: Bool,
        databaseManager: DatabaseManager = .shared
    ) -> TransactionEndPrompt? {
        TransactionEndPrompt.make(
            action: action == .relaunch ? .relaunch : .quit,
            names: openTransactionNames(
                holds: holds,
                connectionName: { databaseManager.session(for: $0)?.connection.name }
            ),
            holds: holds,
            savedUnderManualCommit: holds.contains { databaseManager.commitMode(for: $0.connectionId) == .manual },
            hasUnsavedWork: hasUnsavedTabs,
            effectiveLevel: { ExecutionGateProvider.effectiveSafeModeLevel(for: $0, in: databaseManager) },
            busy: { databaseManager.isLaneBusy(holding: $0) }
        )
    }

    // Runs before anything a quit cannot take back. False keeps the app open: the gate was cancelled, the commit
    // failed, or a transaction is still open after it (a nested one, or one opened since the answer).
    internal static func commitBeforeQuitting(
        _ plan: QuitPlan,
        databaseManager: DatabaseManager = .shared,
        commit: @MainActor ([SessionTransactionTracker.Hold]) async throws -> Bool
            = { try await ConnectionTransactionActions.commitBeforeEnding($0) },
        reportFailure: @MainActor (String) -> Void = { TransactionEndingFlow.showCommitFailure($0, window: nil) }
    ) async -> Bool {
        guard !plan.commits.isEmpty else { return true }
        do {
            guard try await commit(plan.commits) else { return false }
        } catch is CancellationError {
            return false
        } catch {
            reportFailure(error.localizedDescription)
            return false
        }
        let open = Array(databaseManager.sessionTransactions.holds.values)
        guard open.isEmpty else {
            let names = openTransactionNames(
                holds: open,
                connectionName: { databaseManager.session(for: $0)?.connection.name }
            )
            reportFailure(String(
                format: String(localized: "A transaction is still open on %@."),
                ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
            ))
            return false
        }
        return true
    }

    private static func answerTransactionModally(_ prompt: TransactionEndPrompt) -> AlertHelper.TransactionEndAnswer {
        // A quit can come from outside the app, and a background process has no Dock icon to reach the alert by.
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return AlertHelper.answerTransactionEndModally(prompt)
    }

    internal static func approvesDiscardingUnsavedTabs(_ action: RunningWorkAction) -> Bool {
        // A quit can come from outside the app, and a background process has no Dock icon to reach the alert by.
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let relaunches = action == .relaunch
        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes")
        alert.informativeText = relaunches
            ? String(localized: "Some tabs have unsaved edits. Relaunching will discard these changes.")
            : String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
        alert.alertStyle = .warning
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        let confirm = alert.addButton(
            withTitle: relaunches ? String(localized: "Relaunch Anyway") : String(localized: "Quit Anyway")
        )
        confirm.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
