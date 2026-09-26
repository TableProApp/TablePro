//
//  StructureEditingSession+Apply.swift
//  TablePro
//

import Combine
import Foundation
import os
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

        /// A save that is already running holds the tab until it ends. On MongoDB that includes the
        /// check that reads the documents, which can take as long as the query timeout, and a second
        /// press would otherwise start the same save again behind it.
        guard !isApplying, !changeManager.isHeldForSave else { return .refused }

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

        /// Taken before the first suspension and held until the save ends, so a second press is
        /// refused before it can start the same save again, and no edit can land between the
        /// statements being composed and the staged edits being cleared. The edits a save clears
        /// are the ones it held, and only while they are still exactly those.
        guard let hold = changeManager.holdForSave() else { return .refused }
        isApplying = true
        let outcome = await saveHeldChanges(hold.changes, coordinator: coordinator)
        let cleared = changeManager.releaseHold(hold, written: outcome == .applied)
        isApplying = false
        guard outcome == .applied else { return outcome }
        guard cleared else {
            Self.logger.fault("A structure save landed over staged edits it did not write; they stay staged")
            return .refused
        }
        tabData.markAllStale()
        hasLoaded = false
        lastAppliedAt = Date()
        markApplied()
        return outcome
    }

    private func saveHeldChanges(
        _ changes: [SchemaChange],
        coordinator: MainContentCoordinator?
    ) async -> StructureSaveOutcome {
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
            /// Ahead of the destructive-changes prompt, not after it. The review sheet is already
            /// that confirmation and shows the exact script rather than a list of descriptions, so
            /// asking first would be two dialogs for one decision. The HIG's rule is one alert at a
            /// time.
            return presentRebuildReview(prepared, preparedFrom: changes, startedAt: planStart, coordinator: coordinator)
        case .alter(let script):
            return await applyAlterStatements(script, changes: changes, coordinator: coordinator)
        }
    }

    private func applyAlterStatements(
        _ script: SchemaChangeScript,
        changes: [SchemaChange],
        coordinator: MainContentCoordinator?
    ) async -> StructureSaveOutcome {
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

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                script,
                databaseType: connection.type,
                scope: scope
            )
            report(.succeeded(OperationSummary()), startedAt: operationStart, coordinator: coordinator)
            return .applied
        } catch {
            report(.failed(reason: error.localizedDescription), startedAt: operationStart, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator?.contentWindow
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Hands the rebuild script to the review sheet.
    ///
    /// Returns `.refused` because at this point nothing has run and the edits are still staged,
    /// which is exactly what a close has to be stood down for. The apply happens in the sheet's own
    /// action if the user confirms it there.
    private func presentRebuildReview(
        _ prepared: StructureRebuildPlanRunner.Prepared,
        preparedFrom changes: [SchemaChange],
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
                perform: { [weak coordinator] in
                    await self.runRebuild(
                        prepared, preparedFrom: changes, startedAt: operationStart, coordinator: coordinator
                    )
                }
            )
        )
        coordinator.activeSheet = .tableRebuildReview
        return .refused
    }

    /// Runs a confirmed rebuild and does everything a save owes the rest of the app afterwards.
    ///
    /// The table was dropped and recreated, so the grid's rows, the query history and the saved
    /// column layout all describe a table that no longer exists in that form. The ordinary save
    /// path does not record history or clear a layout because an `ALTER` leaves both valid.
    ///
    /// The script was built from the edits staged when Save was pressed, and the sheet can stay up
    /// for as long as the user likes, so it runs only while those are still the staged edits, and
    /// holds them the way a save does until it ends.
    private func runRebuild(
        _ prepared: StructureRebuildPlanRunner.Prepared,
        preparedFrom changes: [SchemaChange],
        startedAt: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) async {
        guard !isApplying, changeManager.getChangesArray() == changes, let hold = changeManager.holdForSave() else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: String(localized: "The staged changes were edited after this script was prepared. Save again to review the new script."),
                window: coordinator?.contentWindow
            )
            return
        }
        isApplying = true
        do {
            try await StructureRebuildPlanRunner.execute(
                prepared,
                databaseType: connection.type,
                operationDescription: String(localized: "Apply Schema Changes")
            )
        } catch {
            changeManager.releaseHold(hold, written: false)
            isApplying = false
            CatalogChangeService.post(
                .changed(CatalogChange(connectionId: connection.id, database: prepared.scope.database, kinds: .tables))
            )
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

        let cleared = changeManager.releaseHold(hold, written: true)
        isApplying = false
        if cleared {
            tabData.markAllStale()
            hasLoaded = false
            lastAppliedAt = Date()
            markApplied()
        } else {
            Self.logger.fault("A table rebuild landed over staged edits it did not write; they stay staged")
        }
        if let clearTarget = coordinator?.selectedColumnLayoutClearTarget() {
            coordinator?.clearColumnLayout(clearTarget)
        }
        DatabaseManager.shared.reportTableDefinitionChange(table: prepared.tableName, in: prepared.scope)
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
