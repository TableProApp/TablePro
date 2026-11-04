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

    // Not gated on the licence: someone who saved the wrong thing has to find this, and the gate at the point of use explains itself.
    var canRewindSelectedTab: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .table else { return false }
        return tab.tableContext.tableName != nil && !safeModeLevel.blocksAllWrites
    }

    private var isDataRewindLicensed: Bool {
        services.featureAccess.isAvailable(.dataRewind)
    }

    func rewindLastSave() {
        guard presentUpsellUnlessLicensed() else { return }
        guard canRewindSelectedTab,
              let tab = tabManager.selectedTab,
              let tableName = tab.tableContext.tableName,
              let tabScope = selectedTabScope
        else { return }

        Task { [weak self] in
            guard let self else { return }
            let records = await services.queryHistoryManager.rewindSnapshots(
                connectionId: connection.id,
                database: tabScope.database,
                schema: tabScope.schema,
                table: tableName,
                limit: 1
            )
            guard let record = records.first else {
                AlertHelper.showInfoSheet(
                    title: String(localized: "Nothing to Restore"),
                    message: String(
                        format: String(localized: "No saved changes to '%@' are being kept."),
                        tableName
                    ),
                    window: contentWindow
                )
                return
            }
            await presentRewind(for: record, scope: scope(for: record))
        }
    }

    // The history drawer can list every connection's saves, so the record's own target decides where this runs.
    func rewindSave(historyId: UUID) {
        guard presentUpsellUnlessLicensed(), canRewindSelectedTab else { return }
        Task { [weak self] in
            guard let self else { return }
            let manager = services.queryHistoryManager
            guard let recordId = await manager.rewindSnapshotId(forHistoryId: historyId),
                  let record = await manager.rewindSnapshot(id: recordId)
            else {
                AlertHelper.showInfoSheet(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "The values this save replaced are no longer being kept."),
                    window: contentWindow
                )
                return
            }
            guard record.connectionId == connection.id else {
                AlertHelper.showInfoSheet(
                    title: String(localized: "Another Connection"),
                    message: String(
                        localized: "This save was made on a different connection. Open that connection to restore it."
                    ),
                    window: contentWindow
                )
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

    private func scope(for record: RewindRecord) -> DatabaseScope {
        DatabaseScope(
            connectionId: connection.id,
            database: record.target.database,
            schema: record.target.schema
        )
    }

    private func presentRewind(for record: RewindRecord, scope: DatabaseScope) async {
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
            rewindPlan = plan
            activeSheet = .rewind
        } catch {
            Self.rewindLogger.error("Could not plan a rewind: \(error.publicLogShape, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Could Not Prepare the Restore"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    func applyRewind() async {
        guard let plan = rewindPlan else { return }
        let executor = RewindExecutor(connection: connection, scope: scope(for: plan.record))
        do {
            let result = try await executor.apply(plan)
            Self.rewindLogger.info("Rewind restored \(result.restoredRows, privacy: .public) rows")
            rewindPlan = nil
            if tabManager.selectedTab?.tableContext.tableName == plan.record.target.table {
                reloadActiveResult()
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

    // From the record, not the live tab: the tab may be on another table by now.
    private func rewindStatementFactory(for record: RewindRecord) -> RowChangeStatementFactory {
        let operation = record.operations.first
        return RowChangeStatementFactory(
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
    }
}
