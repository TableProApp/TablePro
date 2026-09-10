//
//  MainContentCoordinator+ColumnFetchScope.swift
//  TablePro
//

import Foundation
import os

private let columnScopeLog = Logger(subsystem: "com.TablePro", category: "ColumnFetchScope")

extension MainContentCoordinator {
    func selectColumns(for tab: QueryTab) -> [String]? {
        guard tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tab.columnLayout.hiddenColumns.isEmpty,
              let schema = schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab))) else { return nil }

        return ColumnFetchScope.selectColumns(
            schemaColumns: schema.columns,
            hiddenColumns: tab.columnLayout.hiddenColumns,
            primaryKeyColumns: schema.primaryKeys,
            sortColumns: tab.sortState.columns.compactMap(\.columnName)
        )
    }

    func requeryWithColumnScope(debounced: Bool = false) {
        columnScopeRequeryTask?.cancel()
        columnScopeRequeryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounced {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard await self.rebuildSelectedTableColumnScopedQuery() else { return }
            self.runQuery()
        }
    }

    /// Re-resolves the tab by id after the await. An index taken before it points at whatever tab
    /// occupies that slot now, which after a close or a reorder is a different tab entirely.
    @discardableResult
    func rebuildSelectedTableColumnScopedQuery() async -> Bool {
        guard let tab = tabManager.selectedTab,
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName else { return false }
        let tabId = tab.id
        await loadSchemaColumns(for: tableName, scope: scope(for: tab))
        guard !Task.isCancelled,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName else { return false }
        filterCoordinator.rebuildTableQuery(at: index)
        return true
    }

    func loadSchemaColumns(for tableName: String, scope: DatabaseScope?) async {
        guard let scope else { return }
        let key = schemaColumnsKey(tableName, scope: scope)
        await schemaColumns.load(key) { [services] in
            do {
                let columns = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchColumns(table: tableName, schema: scope.schema)
                }
                guard !columns.isEmpty else {
                    columnScopeLog.error("loadSchemaColumns: 0 columns for table=\(tableName, privacy: .public); cannot scope")
                    return nil
                }
                return (columns.map(\.name), columns.filter(\.isPrimaryKey).map(\.name))
            } catch {
                guard !DatabaseCancellationDiagnosis.isCancellation(error) else { return nil }
                columnScopeLog.error("loadSchemaColumns: fetchColumns failed for table=\(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func columnsForVisibilityPicker(for tab: QueryTab, resultColumns: [String]) -> [String] {
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName else { return resultColumns }
        return ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab)))?.columns,
            resultColumns: resultColumns,
            hiddenColumns: tab.columnLayout.hiddenColumns
        )
    }

    func selectedTabSchemaColumns() -> [String]? {
        guard let tab = tabManager.selectedTab,
              let tableName = tab.tableContext.tableName,
              let schema = schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab))),
              !schema.columns.isEmpty else { return nil }
        return schema.columns
    }

    func cachedSchemaColumns(for tab: QueryTab) -> (columns: [String], primaryKeys: [String])? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab)))
    }

    func effectiveResultColumns(for tab: QueryTab) -> [String] {
        selectColumns(for: tab) ?? cachedSchemaColumns(for: tab)?.columns ?? []
    }

    /// Built entirely from the tab's scope. Keying it on where the user is browsing
    /// makes two tabs on same-named tables in different databases share one entry.
    func schemaColumnsKey(_ tableName: String, scope: DatabaseScope?) -> String {
        guard let scope else { return "\(connectionId):::\(tableName)" }
        return "\(scope.connectionId):\(scope.database):\(scope.schema ?? ""):\(tableName)"
    }
}
