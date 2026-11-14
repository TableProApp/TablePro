//
//  MainContentCoordinator+Rewind.swift
//  TablePro
//
//  Restoring the values a committed save replaced.
//

import AppKit
import Foundation
import os

extension MainContentCoordinator {
    nonisolated private static var rewindLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "Rewind")
    }

    // Not gated on the license: someone who just saved the wrong thing must find this. The gate
    // is at the point of use, where it can say what the license is for.
    var canRewindSelectedTab: Bool {
        guard let target = selectedRewindTarget else { return false }
        return services.queryHistoryManager.rewindAvailability.hasSnapshot(for: target)
    }

    // The drawer's save names its own target, so the selected table need not have one kept.
    func canRestoreSave(historyId: UUID) -> Bool {
        isSelectedTabRewindable && services.queryHistoryManager.rewindAvailability.hasSnapshot(forHistoryId: historyId)
    }

    private var isSelectedTabRewindable: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .table else { return false }
        return tab.tableContext.tableName != nil && !safeModeLevel.blocksAllWrites
    }

    private var selectedRewindTarget: RewindAvailability.Target? {
        guard isSelectedTabRewindable,
              let tableName = tabManager.selectedTab?.tableContext.tableName,
              let tabScope = selectedTabScope
        else { return nil }
        return RewindAvailability.Target(
            connectionId: connection.id,
            database: tabScope.database,
            schema: tabScope.schema,
            table: tableName
        )
    }

    private var isDataRewindLicensed: Bool {
        services.featureAccess.isAvailable(.dataRewind)
    }

    func rewindLastSave() {
        guard admitsSheetCommand(), presentUpsellUnlessLicensed() else { return }
        guard canRewindSelectedTab, let target = selectedRewindTarget else { return }

        Task { [weak self] in
            guard let self else { return }
            let records = await services.queryHistoryManager.rewindSnapshots(
                connectionId: target.connectionId,
                database: target.database,
                schema: target.schema,
                table: target.table,
                limit: 1
            )
            guard admitsSheetCommand() else { return }
            // Enabled from the last publish; the save can be pruned or unreadable by the time this reads it.
            guard let record = records.first else {
                AlertHelper.showInfoSheet(
                    title: String(localized: "Nothing to Restore"),
                    message: String(
                        format: String(localized: "No saved changes to '%@' are being kept."),
                        target.table
                    ),
                    window: contentWindow
                )
                return
            }
            await presentRewind(for: record, scope: scope(for: record))
        }
    }

    // The record's own target decides where it runs: a rewind planned against the window's scope
    // would write a same-named table in the wrong database.
    func rewindSave(historyId: UUID) {
        guard admitsSheetCommand(), presentUpsellUnlessLicensed(), canRestoreSave(historyId: historyId) else { return }
        Task { [weak self] in
            guard let self else { return }
            let manager = services.queryHistoryManager
            // Enabled from the last publish; the save can be pruned or unreadable by the time this reads it.
            guard let recordId = await manager.rewindSnapshotId(forHistoryId: historyId),
                  let record = await manager.rewindSnapshot(id: recordId)
            else {
                guard admitsSheetCommand() else { return }
                AlertHelper.showInfoSheet(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "The values this save replaced are no longer being kept."),
                    window: contentWindow
                )
                return
            }
            // The drawer disables another connection's saves; this keeps a stray call off the wrong database.
            guard record.connectionId == connection.id else {
                Self.rewindLogger.error("Refused a rewind of another connection's save")
                return
            }
            await presentRewind(for: record, scope: scope(for: record))
        }
    }

    // The control is reachable without a license on purpose, so this is where the gate explains itself.
    private func presentUpsellUnlessLicensed() -> Bool {
        guard !isDataRewindLicensed else { return true }
        LicenseGateAlert.present(for: .dataRewind, in: contentWindow, access: services.featureAccess)
        return false
    }

    // Where the record's own rows live, not necessarily where the window points.
    private func scope(for record: RewindRecord) -> DatabaseScope {
        DatabaseScope(
            connectionId: connection.id,
            database: record.target.database,
            schema: record.target.schema
        )
    }

    private func presentRewind(for record: RewindRecord, scope: DatabaseScope) async {
        guard admitsSheetCommand() else { return }
        if let refusal = record.blanketRefusal {
            AlertHelper.showInfoSheet(
                title: String(localized: "This Save Cannot Be Restored"),
                message: refusal.explanation,
                window: contentWindow
            )
            return
        }
        await buildAndPresentRewindPlan(for: record, scope: scope)
    }

    private func buildAndPresentRewindPlan(for record: RewindRecord, scope: DatabaseScope) async {
        let executor = RewindExecutor(connection: connection, scope: scope)
        do {
            let plan = try await executor.plan(
                for: record,
                factory: rewindStatementFactory(for: record),
                browseBuilder: services.databaseManager.driver(for: connectionId)?.queryBuildingPluginDriver
            )
            guard admitsSheetCommand() else { return }
            rewindPlan = plan
            activeSheet = .rewind
        } catch {
            Self.rewindLogger.error("Could not plan a rewind: \(error.publicLogShape, privacy: .public)")
            guard admitsSheetCommand() else { return }
            AlertHelper.showErrorSheet(
                title: String(localized: "Could Not Prepare the Restore"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    func applyRewind() async {
        guard let plan = rewindPlan else { return }
        let restoredScope = scope(for: plan.record)
        // Read before the write: the tab in front by the time it lands may be another one.
        let tabId = tabManager.selectedTab?.id
        let executor = RewindExecutor(connection: connection, scope: restoredScope)
        do {
            let result = try await executor.apply(plan)
            Self.rewindLogger.info("Rewind restored \(result.restoredRows, privacy: .public) rows")
            rewindPlan = nil
            if let tabId, tabShows(tabId, table: plan.record.target.table, in: restoredScope) {
                reloadActiveResult(onTab: tabId)
            }
        } catch {
            let writeError = error as? DataWriteError
            AlertHelper.showErrorSheet(
                title: String(localized: "Restore Failed"),
                message: writeError?.errorDescription ?? error.localizedDescription,
                recoverySuggestion: writeError?.recoverySuggestion,
                window: contentWindow
            )
        }
    }

    // Matched on database and schema too: a same-named table elsewhere was not restored.
    private func tabShows(_ tabId: UUID, table: String, in restoredScope: DatabaseScope) -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tableContext.tableName == table,
              let tabScope = scope(for: tab) else { return false }
        return tabScope.database == restoredScope.database && tabScope.schema == restoredScope.schema
    }

    // Shaped by the record, not the live tab: the save's columns and keys matter, and the tab may have moved on.
    private func rewindStatementFactory(for record: RewindRecord) -> RowChangeStatementFactory {
        let operation = record.operations.first
        var factory = RowChangeStatementFactory(
            tableName: record.target.table,
            schemaName: record.target.schema,
            columns: operation?.columns ?? [],
            primaryKeyColumns: operation?.primaryKeyColumns ?? [],
            generatedColumns: Set(record.generatedColumns),
            columnTypeNames: record.columnTypeNames ?? [:],
            databaseType: record.databaseType,
            pluginDriver: changeManager.pluginDriver,
            identityColumns: record.identityColumns.map(Set.init)
        )
        factory.database = record.target.database.isEmpty ? nil : record.target.database
        return factory
    }
}
