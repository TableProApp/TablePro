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

    /// Whether the selected tab is one a save could be restored on. Says nothing about whether
    /// there is a save to restore, which costs a read to find out, and nothing about the licence.
    ///
    /// Deliberately not gated on the licence. Someone who has just saved the wrong thing has to be
    /// able to find this, and a dimmed control they never notice tells them nothing about what the
    /// licence is for. The gate is at the point of use instead, where it can explain itself.
    var canRewindSelectedTab: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .table else { return false }
        return tab.tableContext.tableName != nil && !safeModeLevel.blocksAllWrites
    }

    private var isDataRewindLicensed: Bool {
        services.licenseManager.isFeatureAvailable(.dataRewind)
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

    /// Reached from the history drawer, where the row the user clicked is the save itself.
    ///
    /// The drawer can be scoped to every connection, so the record may belong to another one. A
    /// rewind planned against the window's current scope would then read and write a same-named
    /// table in the wrong database, which is why the record's own target decides where it runs.
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

    /// Returns false, having explained itself, when the licence does not cover this.
    ///
    /// The control is reachable without a licence on purpose, so this is the moment the feature
    /// gets described to the person who just discovered they want it.
    private func presentUpsellUnlessLicensed() -> Bool {
        guard !isDataRewindLicensed else { return true }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(localized: "Data Rewind needs a Starter license")
            alert.informativeText = String(
                localized: "Restore the previous values of rows you already saved. Saves are kept on this Mac for 7 days, encrypted, and never leave it."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Purchase License"))
            AlertHelper.addCancelButton(to: alert, title: String(localized: "Not Now"))
            AlertHelper.present(alert, in: contentWindow) { response in
                guard response == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(SupportLinks.pricing(.featureGate(.dataRewind)))
            }
        }
        return false
    }

    /// Where the record's own rows live, which is not necessarily where the window is pointing.
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
            let plan = try await executor.plan(for: record, factory: rewindStatementFactory(for: record))
            rewindPlan = plan
            activeSheet = .rewind
        } catch {
            Self.rewindLogger.error("Could not plan a rewind: \(error.localizedDescription, privacy: .public)")
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
                runQuery()
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

    /// A factory shaped by the record rather than by the live tab: the columns, keys and computed
    /// columns that matter are the ones the save ran against, and the tab may be on another table
    /// by now.
    private func rewindStatementFactory(for record: RewindRecord) -> RowChangeStatementFactory {
        let operation = record.operations.first
        return RowChangeStatementFactory(
            tableName: record.target.table,
            schemaName: record.target.schema,
            columns: operation?.columns ?? [],
            primaryKeyColumns: operation?.primaryKeyColumns ?? [],
            generatedColumns: Set(record.generatedColumns),
            databaseType: record.databaseType,
            pluginDriver: changeManager.pluginDriver
        )
    }
}
