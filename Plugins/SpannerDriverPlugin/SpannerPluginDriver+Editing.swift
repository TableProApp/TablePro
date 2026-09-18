import Foundation
import TableProPluginKit
import TableProSpannerCore

extension SpannerPluginDriver {
    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        browseRequest(
            table: table, schema: schema, sortColumns: sortColumns, columns: columns,
            filters: [], matchAll: true, limit: limit, offset: offset
        ).encoded()
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        browseRequest(
            table: table, schema: schema, sortColumns: sortColumns, columns: columns,
            filters: queryFilters.map(Self.browseFilter), matchAll: Self.matchesAll(logicMode),
            limit: limit, offset: offset
        ).encoded()
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let request = resolved(browseRequest(
            table: table, schema: schema, sortColumns: [], columns: [],
            filters: queryFilters.map(Self.browseFilter), matchAll: Self.matchesAll(logicMode), limit: 0, offset: 0
        ))
        return try await perform {
            let executor = try self.requireExecutor()
            let rows = try await executor.read(SpannerBrowseRenderer.count(request, dialect: executor.dialect))
            guard case .text(let text)? = rows.first?.first else { return nil }
            return Int(text)
        }
    }

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let statements = SpannerRowEditSQL.statements(
            schema: sqlSchema(schema),
            table: table,
            columns: columns,
            primaryKey: primaryKeyColumns,
            changes: changes.map(Self.rowChange),
            insertedRows: insertedRowData.mapValues { $0.map(Self.spannerCell) },
            deletedRows: deletedRowIndices,
            insertedRowIndices: insertedRowIndices,
            dialect: dialect
        )
        return statements?.map(Self.pluginStatement)
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        SpannerRowEditSQL.identityPreservingInserts(
            schema: sqlSchema(schema),
            table: table,
            columns: columns,
            rows: rows.map { $0.map(Self.spannerCell) },
            dialect: dialect
        ).map(Self.pluginStatement)
    }

    func defaultExportQuery(table: String) -> String? {
        defaultExportQuery(table: table, schema: nil)
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(dialect.qualifiedName(schema: sqlSchema(schema), name: table))"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        let qualified = dialect.qualifiedName(schema: sqlSchema(schema), name: table)
        switch dialect {
        case .googleSQL:
            return ["DELETE FROM \(qualified) WHERE TRUE"]
        case .postgreSQL:
            return ["DELETE FROM \(qualified)"]
        }
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        let keyword = objectType.uppercased()
        guard ["TABLE", "VIEW", "INDEX"].contains(keyword) else { return nil }
        return "DROP \(keyword) \(dialect.qualifiedName(schema: sqlSchema(schema), name: name))"
    }

    private func browseRequest(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        filters: [SpannerBrowseFilter],
        matchAll: Bool,
        limit: Int,
        offset: Int
    ) -> SpannerBrowseRequest {
        let sorts = sortColumns.compactMap { sort -> SpannerBrowseSort? in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return SpannerBrowseSort(column: columns[sort.columnIndex], ascending: sort.ascending)
        }
        return SpannerBrowseRequest(
            table: table,
            schema: schema ?? currentSchema ?? "",
            columns: columns,
            sorts: sorts,
            filters: filters,
            matchAll: matchAll,
            limit: limit,
            offset: offset
        )
    }

    private static func matchesAll(_ logicMode: String) -> Bool {
        logicMode.uppercased() != "OR"
    }

    private static func browseFilter(_ filter: PluginQueryFilter) -> SpannerBrowseFilter {
        SpannerBrowseFilter(
            column: filter.column,
            op: filter.op,
            value: filter.value,
            secondValue: filter.secondValue,
            caseSensitive: filter.isCaseSensitive
        )
    }

    private static func rowChange(_ change: PluginRowChange) -> SpannerRowChange {
        SpannerRowChange(
            rowIndex: change.rowIndex,
            kind: rowChangeKind(change.type),
            cellChanges: change.cellChanges.map {
                SpannerRowChange.CellChange(column: $0.columnName, value: spannerCell($0.newValue))
            },
            originalRow: change.originalRow?.map(spannerCell)
        )
    }

    private static func rowChangeKind(_ type: PluginRowChange.ChangeType) -> SpannerRowChange.Kind {
        switch type {
        case .insert:
            return .insert
        case .update:
            return .update
        case .delete:
            return .delete
        }
    }

    private static func pluginStatement(
        _ statement: SpannerRenderedStatement
    ) -> (statement: String, parameters: [PluginCellValue]) {
        (statement: statement.sql, parameters: statement.parameters.map(pluginCell))
    }
}
