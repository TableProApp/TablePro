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
    /// Safe Mode refused the write, or the user cancelled the destructive-changes prompt. The edits
    /// are still staged.
    case refused
    case failed(String)

    internal var allowsClose: Bool {
        switch self {
        case .nothingToApply, .applied: true
        case .refused, .failed: false
        }
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

        /// Asked before Safe Mode and before the destructive prompt, because an incomplete row is
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

        /// An engine that cannot express this save as `ALTER` statements recreates the table
        /// instead, and a rebuild is never run from a Save press. It is shown in full, with what it
        /// cannot carry over, and confirmed before anything is dropped.
        ///
        /// Ahead of the destructive-changes prompt, not after it. The review sheet is already that
        /// confirmation and shows the exact script rather than a list of descriptions, so asking
        /// first would be two dialogs for one decision. The HIG's rule is one alert at a time.
        if StructureTableRebuildHandler.requiresRebuild(
            changes: changes,
            support: PluginManager.shared.foreignKeyEditSupport(for: connection.type)
        ) {
            return await presentRebuildReview(changes: changes, coordinator: coordinator)
        }

        let destructiveChanges = changes.filter(\.requiresDataMigration)
        if !destructiveChanges.isEmpty {
            let message = String(
                format: String(localized: "The following changes may cause data loss:\n\n%@\n\nDo you want to proceed?"),
                destructiveChanges.map(\.description).joined(separator: "\n")
            )
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Destructive Changes"),
                message: message,
                confirmButton: String(localized: "Apply Changes"),
                cancelButton: String(localized: "Cancel"),
                window: coordinator?.contentWindow
            )
            guard confirmed else { return .refused }
        }

        /// Started here, not at the top of the function. The destructive-changes prompt sits above
        /// this and the user can take as long as they like over it, so a clock started earlier
        /// measures their reading time and reports an instant ALTER as having taken a minute.
        let operationStart = ContinuousClock.Instant.now
        isApplying = true

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: tableName,
                changes: changes,
                databaseType: connection.type,
                scope: scope
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
            report(.failed(reason: error.localizedDescription), startedAt: operationStart, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator?.contentWindow
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Builds the rebuild script and hands it to the review sheet.
    ///
    /// Returns `.refused` because at this point nothing has run and the edits are still staged,
    /// which is exactly what a close has to be stood down for. The apply happens in the sheet's own
    /// action if the user confirms it there.
    private func presentRebuildReview(
        changes: [SchemaChange],
        coordinator: MainContentCoordinator?
    ) async -> StructureSaveOutcome {
        guard let coordinator else { return .refused }
        let operationStart = ContinuousClock.Instant.now
        let reviewScope = scope

        do {
            let prepared = try await StructureTableRebuildHandler.prepare(
                changes: changes,
                tableName: tableName,
                scope: reviewScope
            )
            coordinator.tableRebuildRequest = TableRebuildReviewRequest(
                tableName: tableName,
                scope: reviewScope,
                plan: prepared.plan,
                actionTitle: String(localized: "Apply and Rebuild"),
                perform: { [weak coordinator] in
                    await self.runRebuild(
                        prepared,
                        startedAt: operationStart,
                        coordinator: coordinator
                    )
                }
            )
            coordinator.activeSheet = .tableRebuildReview
            return .refused
        } catch {
            report(.failed(reason: error.localizedDescription), startedAt: operationStart, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator.contentWindow
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Runs a confirmed rebuild and does everything a save owes the rest of the app afterwards.
    ///
    /// The table was dropped and recreated, so the grid's rows, the query history and the saved
    /// column layout all describe a table that no longer exists in that form. The ordinary save
    /// path does not record history or clear a layout because an `ALTER` leaves both valid.
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
                operationDescription: String(localized: "Apply Schema Changes")
            )
        } catch {
            isApplying = false
            report(.failed(reason: error.localizedDescription), startedAt: startedAt, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator?.contentWindow
            )
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
