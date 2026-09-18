//
//  RestoredHiddenColumns.swift
//  TablePro
//

import Foundation

/// Puts each restored table tab's hidden columns back on the tab.
///
/// Hidden columns are not part of the tab record: they live in the per-table layout store, keyed by
/// connection, database, schema and table. Only the tab selected at launch used to read them, so
/// every other restored tab came back showing columns the user had hidden, and the first hide there
/// wrote that near-empty set over the table's stored one and took the rest with it.
///
/// This runs at restore rather than at first load on purpose. A tab whose first load fails never
/// auto-loads again, and the manual re-run skips the first-load path entirely, so a restore keyed
/// to that path would miss exactly the tab the user is trying to recover.
@MainActor
internal enum RestoredHiddenColumns {
    internal static func hydrate(
        _ tabs: inout [QueryTab],
        connectionId: UUID,
        persister: any ColumnLayoutPersisting
    ) {
        for index in tabs.indices {
            hydrate(&tabs[index], connectionId: connectionId, persister: persister)
        }
    }

    internal static func hydrate(
        _ tab: inout QueryTab,
        connectionId: UUID,
        persister: any ColumnLayoutPersisting
    ) {
        guard tab.tabType == .table,
              tab.columnLayout.hiddenColumns.isEmpty,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return }

        let key = ColumnLayoutTableKey(
            connectionId: connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: tableName
        )
        let restored = persister.loadHiddenColumns(for: key)
        guard !restored.isEmpty else { return }
        tab.columnLayout.hiddenColumns = restored
    }
}
