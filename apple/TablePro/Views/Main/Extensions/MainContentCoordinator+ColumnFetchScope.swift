//
//  MainContentCoordinator+ColumnFetchScope.swift
//  TablePro
//

import Foundation
import os

private let columnScopeLog = Logger(subsystem: "com.TablePro", category: "ColumnFetchScope")

// The columns one open read before its rows, handed to the definition read of that same open.
struct FirstLoadColumnRead {
    let key: String
    let columns: [ColumnInfo]
    let startedAt: ContinuousClock.Instant
}

struct TableQueryColumns {
    let columns: [String]
    let columnTypes: [ColumnType]
    let selectColumns: [String]?
    let unloadedValues: UnloadedValuePlan?
}

extension MainContentCoordinator {
    func selectColumns(for tab: QueryTab) -> [String]? {
        selectColumns(for: tab, schema: tableSchemaColumns(for: tab))
    }

    func selectColumns(for tab: QueryTab, schema: SchemaColumnStore.Entry?) -> [String]? {
        guard let schema else { return nil }
        if let scoped = scopedColumns(for: tab, schema: schema) { return scoped }
        // A deferred column is spelled out in the select list, so the list cannot be `*`.
        return unloadedValuePlan(for: tab, selecting: schema.columns, schema: schema) == nil ? nil : schema.columns
    }

    func unloadedValuePlan(for tab: QueryTab) -> UnloadedValuePlan? {
        unloadedValuePlan(for: tab, schema: tableSchemaColumns(for: tab))
    }

    func unloadedValuePlan(for tab: QueryTab, schema: SchemaColumnStore.Entry?) -> UnloadedValuePlan? {
        guard let schema else { return nil }
        return unloadedValuePlan(
            for: tab,
            selecting: scopedColumns(for: tab, schema: schema) ?? schema.columns,
            schema: schema
        )
    }

    func tableQueryColumns(for tab: QueryTab) -> TableQueryColumns {
        let (columns, columnTypes) = queryColumns(for: tab)
        return TableQueryColumns(
            columns: columns,
            columnTypes: columnTypes,
            selectColumns: selectColumns(for: tab),
            unloadedValues: unloadedValuePlan(for: tab)
        )
    }

    // As a first page builds it from this list alone, before any rows arrive to type its filters.
    func tableQueryColumns(for tab: QueryTab, builtOn schema: SchemaColumnStore.Entry) -> TableQueryColumns {
        let selected = effectiveResultColumns(for: tab, schema: schema)
        let (columns, columnTypes) = appendingHiddenColumns(
            to: selected, types: schema.columnTypes(aligningWith: selected), of: tab, schema: schema
        )
        return TableQueryColumns(
            columns: columns,
            columnTypes: columnTypes,
            selectColumns: selectColumns(for: tab, schema: schema),
            unloadedValues: unloadedValuePlan(for: tab, schema: schema)
        )
    }

    // The size and head columns a query ends with, from the list its SQL was built on: a rerun sends that SQL unchanged.
    func unloadedValueLayout(for tab: QueryTab, sql: String) -> UnloadedValueLayout? {
        let schema = catalogPageList(of: tab, sql: sql) ?? tableSchemaColumns(for: tab)
        guard let plan = unloadedValuePlan(for: tab, schema: schema),
              let selected = selectColumns(for: tab, schema: schema)
        else { return nil }
        return plan.layout(for: selected)
    }

    var defersLargeValues: Bool {
        PluginManager.shared.largeValueFunctions(for: connection.type) != nil
    }

    private func tableSchemaColumns(for tab: QueryTab) -> SchemaColumnStore.Entry? {
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName else { return nil }
        return schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab)))
    }

    private func scopedColumns(for tab: QueryTab, schema: SchemaColumnStore.Entry) -> [String]? {
        guard !tab.columnLayout.hiddenColumns.isEmpty else { return nil }
        return ColumnFetchScope.selectColumns(
            schemaColumns: schema.columns,
            hiddenColumns: tab.columnLayout.hiddenColumns,
            primaryKeyColumns: schema.primaryKeys,
            sortColumns: tab.sortState.columns.compactMap(\.columnName),
            valueFilteredColumns: valueFilteredColumnNames(of: tab)
        )
    }

    private func unloadedValuePlan(
        for tab: QueryTab,
        selecting columns: [String],
        schema: SchemaColumnStore.Entry
    ) -> UnloadedValuePlan? {
        UnloadedValuePlan.resolve(
            selectedColumns: columns,
            columnTypes: schema.columnTypes,
            primaryKeys: schema.primaryKeys,
            sortColumns: tab.sortState.columns.compactMap(\.columnName),
            valueFilteredColumns: valueFilteredColumnNames(of: tab),
            functions: PluginManager.shared.largeValueFunctions(for: connection.type),
            inlineByteLimit: connection.binaryInlineLimitBytes
        )
    }

    private func valueFilteredColumnNames(of tab: QueryTab) -> [String] {
        tab.valueFilter.activeColumns.compactMap { tab.valueFilter.columnName(forColumn: $0) }
    }

    func requeryWithColumnScope(forTab tabId: UUID, debounced: Bool = false) {
        columnScopeRequeryTask?.cancel()
        columnScopeRequeryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounced {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard await self.rebuildColumnScopedQuery(forTab: tabId) else { return }
            self.runQuery(onTab: tabId, viewport: .keepPlace)
        }
    }

    // Re-resolves the tab by id after the await: an index taken before it can name another tab after a close or reorder.
    @discardableResult
    func rebuildColumnScopedQuery(forTab tabId: UUID) async -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName else { return false }
        await loadSchemaColumns(for: tableName, scope: scope(for: tab))
        guard !Task.isCancelled,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName else { return false }
        filterCoordinator.rebuildTableQuery(at: index)
        return true
    }

    var schemaColumnClassifier: ColumnTypeClassifier {
        ColumnTypeClassifier(family: SQLTypeFamily.of(connection.type))
    }

    // Nil when the cache answered or another caller's read was joined: only this call's own read is known to be this fresh.
    @discardableResult
    func loadSchemaColumns(for tableName: String, scope: DatabaseScope?) async -> FirstLoadColumnRead? {
        guard let scope else { return nil }
        let key = schemaColumnsKey(tableName, scope: scope)
        let classifier = schemaColumnClassifier
        let startedAt = ContinuousClock.now
        var read: FirstLoadColumnRead?
        await schemaColumns.load(key) { [services] in
            do {
                let columns = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchColumns(table: tableName, schema: scope.schema)
                }
                guard !columns.isEmpty else {
                    columnScopeLog.error("loadSchemaColumns: 0 columns for table=\(tableName, privacy: .private(mask: .hash)); cannot scope")
                    return nil
                }
                read = FirstLoadColumnRead(key: key, columns: columns, startedAt: startedAt)
                return SchemaColumnStore.Entry(fetchedColumns: columns, classifier: classifier)
            } catch {
                guard !DatabaseCancellationDiagnosis.isCancellation(error) else { return nil }
                columnScopeLog.error("loadSchemaColumns: fetchColumns failed for table=\(tableName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
                return nil
            }
        }
        return read
    }

    // Taken once, by the run this open starts. A definition change after the read began makes it the old table's.
    func takeFirstLoadColumns(tabId: UUID, tableName: String?, scope: DatabaseScope) -> [ColumnInfo]? {
        guard let read = firstLoadColumnReads.removeValue(forKey: tabId),
              let tableName,
              read.key == schemaColumnsKey(tableName, scope: scope),
              tabSessionRegistry.definitionIsCurrent(asOf: read.startedAt, for: tabId)
        else { return nil }
        return read.columns
    }

    /// The metadata a load commits with its rows after it fetched the table's definition itself, and
    /// the same definition's columns in place of the set a definition change dropped. A load that
    /// started before the latest definition change still commits what it read, and the tab stays
    /// marked, but its columns never reach the cache the next query builds its select list from.
    func adoptLoadedDefinition(
        _ schema: FetchedTableSchema?,
        of tableName: String?,
        in scope: DatabaseScope,
        readBy claim: TabExecutionClaim
    ) -> ParsedSchemaMetadata? {
        guard let schema else { return nil }
        if let tableName, !schema.columns.isEmpty,
           tabSessionRegistry.definitionIsCurrent(asOf: claim.startedAt, for: claim.tabId) {
            schemaColumns.store(
                SchemaColumnStore.Entry(fetchedColumns: schema.columns, classifier: schemaColumnClassifier),
                for: schemaColumnsKey(tableName, scope: scope)
            )
        }
        return parseSchemaMetadata(schema)
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

    func cachedSchemaColumns(for tab: QueryTab) -> SchemaColumnStore.Entry? {
        guard let tableName = tab.tableContext.tableName else { return nil }
        return schemaColumns.cached(schemaColumnsKey(tableName, scope: scope(for: tab)))
    }

    func effectiveResultColumns(for tab: QueryTab) -> [String] {
        selectColumns(for: tab) ?? cachedSchemaColumns(for: tab)?.columns ?? []
    }

    func effectiveResultColumns(for tab: QueryTab, schema: SchemaColumnStore.Entry) -> [String] {
        selectColumns(for: tab, schema: schema) ?? schema.columns
    }

    /// The columns a table tab's SQL is built against, each paired with its type. Loaded rows are
    /// the authority once they exist. Before that the table's schema answers, because an untyped
    /// filter guesses from the value's text and sends `0123` to a text column as a number.
    func queryColumns(for tab: QueryTab) -> (columns: [String], columnTypes: [ColumnType]) {
        let buffer = tabSessionRegistry.tableRows(for: tab.id)
        let schema = cachedSchemaColumns(for: tab)
        guard buffer.columns.isEmpty else {
            return appendingHiddenColumns(to: buffer.columns, types: buffer.columnTypes, of: tab, schema: schema)
        }
        let columns = effectiveResultColumns(for: tab)
        return appendingHiddenColumns(
            to: columns, types: schema?.columnTypes(aligningWith: columns) ?? [], of: tab, schema: schema
        )
    }

    // A hidden column leaves the SELECT, not the table, so a filter on it still needs its type. It goes
    // after the selected columns, so no sort index moves, and only while the SELECT names its columns,
    // so a driver projecting the whole list never fetches it.
    private func appendingHiddenColumns(
        to columns: [String],
        types: [ColumnType],
        of tab: QueryTab,
        schema: SchemaColumnStore.Entry?
    ) -> (columns: [String], columnTypes: [ColumnType]) {
        guard let schema, types.count == columns.count,
              scopedColumns(for: tab, schema: schema) != nil else { return (columns, types) }
        let selected = Set(columns)
        let hidden = schema.columns.filter { tab.columnLayout.hiddenColumns.contains($0) && !selected.contains($0) }
        let hiddenTypes = schema.columnTypes(aligningWith: hidden)
        guard !hidden.isEmpty, hiddenTypes.count == hidden.count else { return (columns, types) }
        return (columns + hidden, types + hiddenTypes)
    }

    // Built from the tab's scope alone, not where the user browses, with names by bytes, so tables in two databases,
    // or two tables or schemas whose names Swift's String equates, keep entries of their own.
    func schemaColumnsKey(_ tableName: String, scope: DatabaseScope?) -> String {
        let table = CatalogName(tableName).exactKey
        guard let scope else { return "\(connectionId):::\(table)" }
        let binding = scope.isSessionBound ? ":session" : ""
        let database = CatalogName(scope.database).exactKey
        let schema = CatalogName(scope.schema ?? "").exactKey
        return "\(scope.connectionId):\(database):\(schema):\(table)\(binding)"
    }
}
