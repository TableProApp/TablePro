//
//  TableQueryBuilder.swift
//  TablePro
//
//  Service responsible for building SQL queries for table operations.
//  Handles sorting and filtering query construction.
//

import Foundation
import TableProPluginKit

/// Service for building SQL queries for table operations
struct TableQueryBuilder {
    // MARK: - Properties

    private let databaseType: DatabaseType
    private var pluginDriver: (any PluginDatabaseDriver)?
    private let dialect: SQLDialectDescriptor?
    private let dialectQuote: (String) -> String

    // MARK: - Initialization

    init(
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)? = nil,
        dialect: SQLDialectDescriptor? = nil,
        dialectQuote: ((String) -> String)? = nil
    ) {
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
        self.dialect = dialect
        self.dialectQuote = dialectQuote ?? { name in
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
    }

    mutating func setPluginDriver(_ driver: (any PluginDatabaseDriver)?) {
        pluginDriver = driver
    }

    // MARK: - Identifier Quoting

    func quoteIdentifier(_ name: String) -> String {
        quote(name)
    }

    private func quote(_ name: String) -> String {
        if let pluginDriver { return pluginDriver.quoteIdentifier(name) }
        return dialectQuote(name)
    }

    // MARK: - Query Building

    private func qualifiedTable(_ tableName: String, schema: String?) -> String {
        if let schema {
            return "\(quote(schema)).\(quote(tableName))"
        }
        return quote(tableName)
    }

    func buildBaseQuery(
        tableName: String,
        schemaName: String? = nil,
        sortState: SortState? = nil,
        columns: [String] = [],
        selectColumns: [String]? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        if let pluginDriver {
            let targetColumns = selectColumns ?? columns
            let sortCols = SortColumnResolver.resolvedIndices(
                for: sortState, displayColumns: columns, targetColumns: targetColumns
            )
            if let result = pluginDriver.buildBrowseQuery(
                table: tableName, schema: schemaName, sortColumns: sortCols,
                columns: targetColumns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        var query = "SELECT \(selectClause(selectColumns)) FROM \(quotedTable)"

        if let orderBy = orderByOrOffsetFetchDefault(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " \(buildPaginationClause(limit: limit, offset: offset))"
        return query
    }

    func buildFilteredQuery(
        tableName: String,
        schemaName: String? = nil,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        sortState: SortState? = nil,
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        selectColumns: [String]? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        if let pluginDriver {
            let targetColumns = selectColumns ?? columns
            let sortCols = SortColumnResolver.resolvedIndices(
                for: sortState, displayColumns: columns, targetColumns: targetColumns
            )
            let queryFilters = filters
                .filter { $0.isEnabled && !$0.columnName.isEmpty }
                .map(\.asPluginQueryFilter)
            if let result = pluginDriver.buildFilteredQuery(
                table: tableName, schema: schemaName, queryFilters: queryFilters,
                logicMode: logicMode == .and ? "and" : "or",
                sortColumns: sortCols, columns: targetColumns, limit: limit, offset: offset,
                columnKinds: pluginColumnKinds(columns: columns, columnTypes: columnTypes)
            ) {
                return result
            }
        }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        var query = "SELECT \(selectClause(selectColumns)) FROM \(quotedTable)"

        if let dialect {
            let activeFilters = filters.filter { $0.isEnabled }
            let filterGen = FilterSQLGenerator(
                dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote
            )
            let whereClause = filterGen.generateWhereClause(from: activeFilters, logicMode: logicMode)
            if !whereClause.isEmpty {
                query += " \(whereClause)"
            }
        }

        if let orderBy = orderByOrOffsetFetchDefault(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " \(buildPaginationClause(limit: limit, offset: offset))"
        return query
    }

    func buildKeyPatternBrowseQuery(
        tableName: String,
        schemaName: String? = nil,
        pattern: String,
        typeScope: String?,
        sortState: SortState? = nil,
        columns: [String] = [],
        selectColumns: [String]? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        if let pluginDriver {
            let targetColumns = selectColumns ?? columns
            let sortCols = SortColumnResolver.resolvedIndices(
                for: sortState, displayColumns: columns, targetColumns: targetColumns
            )
            var tuples: [(column: String, op: String, value: String)] = []
            let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
            if !trimmedPattern.isEmpty {
                tuples.append((column: "Key", op: "MATCH", value: trimmedPattern))
            }
            if let typeScope, !typeScope.isEmpty {
                tuples.append((column: "Type", op: "=", value: typeScope))
            }
            if let result = pluginDriver.buildFilteredQuery(
                table: tableName, schema: schemaName, filters: tuples,
                logicMode: "and", sortColumns: sortCols,
                columns: targetColumns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        return buildBaseQuery(
            tableName: tableName, schemaName: schemaName, sortState: sortState,
            columns: columns, selectColumns: selectColumns, limit: limit, offset: offset
        )
    }

    func buildFilteredCountQuery(
        tableName: String,
        schemaName: String? = nil,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        columns: [String] = [],
        columnTypes: [ColumnType] = []
    ) -> String? {
        guard let dialect else { return nil }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        let activeFilters = filters.filter { $0.isEnabled }
        let filterGen = FilterSQLGenerator(
            dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote
        )
        let whereClause = filterGen.generateWhereClause(from: activeFilters, logicMode: logicMode)

        guard !whereClause.isEmpty else {
            return "SELECT COUNT(*) FROM \(quotedTable)"
        }
        return "SELECT COUNT(*) FROM \(quotedTable) \(whereClause)"
    }

    // MARK: - Private Helpers

    private func pluginColumnKinds(columns: [String], columnTypes: [ColumnType]) -> [String: PluginColumnKind] {
        ColumnTypeSQLQuoting.lookupByName(columns: columns, columnTypes: columnTypes)
            .mapValues(\.pluginColumnKind)
    }

    private func selectClause(_ selectColumns: [String]?) -> String {
        guard let selectColumns, !selectColumns.isEmpty else { return "*" }
        return selectColumns.map { quote($0) }.joined(separator: ", ")
    }

    private func buildPaginationClause(limit: Int, offset: Int) -> String {
        if let dialect, dialect.paginationStyle == .offsetFetch {
            return "OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        }
        return "LIMIT \(limit) OFFSET \(offset)"
    }

    private func orderByOrOffsetFetchDefault(sortState: SortState?, columns: [String]) -> String? {
        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            return orderBy
        }
        guard dialect?.paginationStyle == .offsetFetch else { return nil }
        let defaultOrderBy = dialect?.offsetFetchOrderBy ?? "ORDER BY (SELECT NULL)"
        return defaultOrderBy.isEmpty ? nil : defaultOrderBy
    }

    private func buildOrderByClause(sortState: SortState?, columns: [String]) -> String? {
        guard let state = sortState, state.isSorting else { return nil }

        let parts = state.columns.compactMap { sortCol -> String? in
            guard let columnName = SortColumnResolver.clauseColumnName(for: sortCol, displayColumns: columns) else {
                return nil
            }
            let direction = sortCol.direction == .ascending ? "ASC" : "DESC"
            let quotedColumn = quote(columnName)
            return "\(quotedColumn) \(direction)"
        }

        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }
}
