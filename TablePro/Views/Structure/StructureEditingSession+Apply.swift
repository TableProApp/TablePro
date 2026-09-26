//
//  StructureEditingSession+Apply.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// What happened when a tab was asked to apply its staged structure edits.
///
/// The distinction that matters is `allowsClose`. A close offers Save because the tab holds staged
/// ALTERs; if the save did not put them in the database, closing destroys them, so every way of not
/// applying them has to stand the close down rather than report success.
internal enum StructureSaveOutcome: Equatable {
    /// Nothing was staged. The close may proceed: there is no work to lose.
    case nothingToApply
    case applied
    /// Safe Mode refused the write, or the user cancelled at the execution gate's confirmation. The
    /// edits are still staged.
    case refused
    case failed(String)

    internal var allowsClose: Bool {
        switch self {
        case .nothingToApply, .applied: true
        case .refused, .failed: false
        }
    }
}

/// How a save that did not apply ends, read from the error alone so it can be tested without
/// presenting anything.
///
/// The gate's sheet is the one confirmation a save gets, so Cancel there is the ordinary way to
/// back out, and it ends quietly the way closing any confirmation does. Answering it with an
/// "Error Applying Changes" sheet put a second dialog in front of the user for the choice they had
/// just made.
internal enum StructureApplyFailure: Equatable {
    case cancelledByUser
    case refused(String)
    case failed(String)

    internal init(_ error: any Error) {
        guard let gateError = error as? ExecutionGateError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch gateError {
        case .cancelledByUser:
            self = .cancelledByUser
        case .denied(let reason):
            self = .refused(reason)
        }
    }

    internal var outcome: StructureSaveOutcome {
        switch self {
        case .cancelledByUser, .refused: .refused
        case .failed(let message): .failed(message)
        }
    }

    /// What the error sheet says. Nil for a Cancel, which shows nothing.
    internal var message: String? {
        switch self {
        case .cancelledByUser: nil
        case .refused(let reason), .failed(let reason): reason
        }
    }

    /// A refusal and a Cancel both stop at the gate, before the first statement, so neither is a
    /// failed operation to report or a reason to reload the catalog.
    internal var reportsFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

internal extension StructureEditingSession {
    /// Applies this tab's staged ALTERs, with no mounted view required.
    ///
    /// This is deliberately not on `TableStructureView`. `hasUnsavedWork` reads the session, so a
    /// tab that is merely open, or open on its Data view, can raise the unsaved-changes prompt; the
    /// save it offers used to dispatch through `coordinator.structureActions`, a weak slot only the
    /// mounted structure view ever fills. Answering Save from anywhere else ran nothing, reported
    /// success, and closed the tab over the work.
    func applyStagedChanges(coordinator: MainContentCoordinator?) async -> StructureSaveOutcome {
        /// Asked before Safe Mode, so a tab with nothing staged is never refused. `.refused` stands
        /// the close down, and refusing a save that had no work to do would leave the user unable to
        /// close the tab through Save at all.
        let changes = changeManager.getChangesArray()
        guard !changes.isEmpty else { return .nothingToApply }

        /// Asked before Safe Mode and before the gate's confirmation, because an incomplete row is
        /// not a change the user meant to make. Without this a foreign key added and never filled
        /// in reached DDL generation as `ADD CONSTRAINT "" FOREIGN KEY () REFERENCES "" ()`, which
        /// SQLite refused as an unsupported operation and MySQL sent to the server as a syntax
        /// error. `canCommit` and the messages behind it already existed and nothing read them.
        ///
        /// Save stays enabled and explains, rather than going grey. A disabled Save with no reason
        /// beside it leaves the user hunting for which of several staged rows is wrong, and there
        /// is nowhere in the bottom bar to put the explanation; the sheet names every problem at
        /// once.
        guard changeManager.canCommit else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Some Changes Are Incomplete"),
                message: changeManager.validationSummary,
                window: coordinator?.contentWindow
            )
            return .refused
        }

        let liveSafeModeLevel = coordinator?.safeModeLevel ?? connection.safeModeLevel
        guard !liveSafeModeLevel.blocksAllWrites else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Safe Mode Is Read-Only"),
                message: String(
                    localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
                ),
                window: coordinator?.contentWindow
            )
            return .refused
        }

        let planStart = ContinuousClock.Instant.now
        let plan: StructureSavePlan
        do {
            plan = try await stagedSavePlan(for: changes)
        } catch {
            report(.failed(reason: error.localizedDescription), startedAt: planStart, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator?.contentWindow
            )
            return .failed(error.localizedDescription)
        }

        switch plan {
        case .rebuild(let prepared):
            /// An engine that cannot express this save as `ALTER` statements recreates the table
            /// instead, and a rebuild is never run from a Save press. It is shown in full, with what
            /// it cannot carry over, and confirmed before anything is dropped.
            ///
            /// The review sheet is that confirmation and shows the exact script, so the run it
            /// starts tells the gate it was confirmed rather than stacking the gate's own sheet over
            /// it for the same decision. The HIG's rule is one alert at a time.
            return presentRebuildReview(prepared, startedAt: planStart, coordinator: coordinator)
        case .alter(let statements):
            return await applyAlterStatements(statements, coordinator: coordinator)
        }
    }

    /// The execution gate is the one confirmation an `ALTER` save gets. It shows the statements
    /// verbatim, applies the connection's Safe Mode level, and confirms a change that can lose data
    /// at every level because `SchemaStatementGenerator` marks those statements destructive. The
    /// editor used to ask first with a list of descriptions, which made one decision two dialogs,
    /// and three with Touch ID.
    private func applyAlterStatements(
        _ statements: [SchemaStatement],
        coordinator: MainContentCoordinator?
    ) async -> StructureSaveOutcome {
        let operationStart = ContinuousClock.Instant.now
        isApplying = true

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                statements,
                databaseType: connection.type,
                scope: scope,
                gate: executionGate
            )
            changeManager.discardChanges()
            tabData.markAllStale()
            hasLoaded = false
            lastAppliedAt = Date()
            isApplying = false
            markApplied()
            report(.succeeded(OperationSummary()), startedAt: operationStart, coordinator: coordinator)
            return .applied
        } catch {
            isApplying = false
            let failure = StructureApplyFailure(error)
            present(failure, startedAt: operationStart, coordinator: coordinator)
            return failure.outcome
        }
    }

    private func present(
        _ failure: StructureApplyFailure,
        startedAt: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) {
        guard let message = failure.message else { return }
        if failure.reportsFailure {
            report(.failed(reason: message), startedAt: startedAt, coordinator: coordinator)
        }
        AlertHelper.showErrorSheet(
            title: String(localized: "Error Applying Changes"),
            message: message,
            window: coordinator?.contentWindow
        )
    }

    /// Hands the rebuild script to the review sheet.
    ///
    /// Returns `.refused` because at this point nothing has run and the edits are still staged,
    /// which is exactly what a close has to be stood down for. The apply happens in the sheet's own
    /// action if the user confirms it there.
    private func presentRebuildReview(
        _ prepared: StructureRebuildPlanRunner.Prepared,
        startedAt operationStart: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) -> StructureSaveOutcome {
        guard let coordinator else { return .refused }
        coordinator.tableRebuildRequest = TableRebuildReviewRequest(
            tableName: prepared.tableName,
            scope: prepared.scope,
            plan: prepared.plan,
            action: TableRebuildReviewRequest.Action(
                title: String(localized: "Apply and Rebuild"),
                operationDescription: Self.applyOperationDescription,
                perform: { [weak coordinator] in
                    await self.runRebuild(prepared, startedAt: operationStart, coordinator: coordinator)
                }
            )
        )
        coordinator.activeSheet = .tableRebuildReview
        return .refused
    }

    private static var applyOperationDescription: String {
        String(localized: "Apply Schema Changes")
    }

    /// Runs a confirmed rebuild and does everything a save owes the rest of the app afterwards.
    ///
    /// The table was dropped and recreated, so the grid's rows, the query history and the saved
    /// column layout all describe a table that no longer exists in that form. The ordinary save
    /// path does not record history or clear a layout because an `ALTER` leaves both valid.
    ///
    /// Only the review sheet's own button reaches this, so the gate is told the script was
    /// confirmed. Touch ID and the Read-Only refusal still apply.
    private func runRebuild(
        _ prepared: StructureRebuildPlanRunner.Prepared,
        startedAt: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) async {
        isApplying = true
        do {
            try await StructureRebuildPlanRunner.execute(
                prepared,
                databaseType: connection.type,
                operationDescription: Self.applyOperationDescription,
                isConfirmationPreCleared: true,
                gate: executionGate
            )
        } catch {
            isApplying = false
            let failure = StructureApplyFailure(error)
            if failure.reportsFailure {
                CatalogChangeService.post(
                    .changed(CatalogChange(connectionId: connection.id, database: prepared.scope.database, kinds: .tables))
                )
            }
            present(failure, startedAt: startedAt, coordinator: coordinator)
            return
        }

        await QueryHistoryManager.shared.record(
            QueryHistoryRecordRequest(
                query: prepared.plan.scriptStatements
                    .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                    .joined(separator: "\n"),
                connectionId: prepared.scope.connectionId,
                databaseName: prepared.scope.database,
                databaseType: connection.type,
                source: .structureDDL,
                executionTime: 0,
                rowCount: -1,
                wasSuccessful: true
            )
        )

        changeManager.discardChanges()
        tabData.markAllStale()
        hasLoaded = false
        lastAppliedAt = Date()
        isApplying = false
        markApplied()
        if let clearTarget = coordinator?.selectedColumnLayoutClearTarget() {
            coordinator?.clearColumnLayout(clearTarget)
        }
        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: connection.id))
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: connection.id, database: prepared.scope.database, kinds: .tables))
        )
        report(.succeeded(OperationSummary()), startedAt: startedAt, coordinator: coordinator)
    }

    /// Reported against this tab's own database, never the one the sidebar is browsing. A batch
    /// close applies tabs pointed at other databases, so ambient state names the wrong one.
    private func report(
        _ outcome: OperationOutcome,
        startedAt: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .schemaChange,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: databaseName,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
