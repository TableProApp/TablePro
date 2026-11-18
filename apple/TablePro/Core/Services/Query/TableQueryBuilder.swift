//
//  TableQueryBuilder.swift
//  TablePro
//
//  Service responsible for building SQL queries for table operations.
//  Handles sorting and filtering query construction.
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

/// Service for building SQL queries for table operations
struct TableQueryBuilder {
    // MARK: - Properties

    private let databaseType: DatabaseType
    private var pluginDriver: (any PluginDatabaseDriver)?
    private let dialect: SQLDialectDescriptor?
    private let pagination: PaginationCapability
    private let dialectQuote: (String) -> String
    private var sessionDriver: (any DatabaseDriver)?

    // MARK: - Initialization

    init(
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)? = nil,
        dialect: SQLDialectDescriptor? = nil,
        pagination: PaginationCapability,
        dialectQuote: @escaping (String) -> String,
        sessionDriver: (any DatabaseDriver)? = nil
    ) {
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
        self.dialect = dialect
        self.pagination = pagination
        self.dialectQuote = dialectQuote
        self.sessionDriver = sessionDriver
    }

    mutating func setPluginDriver(_ driver: (any PluginDatabaseDriver)?) {
        pluginDriver = driver
    }

    func usesPluginDriver(_ driver: (any PluginDatabaseDriver)?) -> Bool {
        pluginDriver === driver
    }

    mutating func setSessionDriver(_ driver: (any DatabaseDriver)?) {
        sessionDriver = driver
    }

    func usesSessionDriver(_ driver: (any DatabaseDriver)?) -> Bool {
        sessionDriver === driver
    }

    // Read when the query is built: a `SET sql_mode` can turn MySQL's backslash escape off mid-session.
    private var stringEscapes: SQLStringEscapes {
        SQLLexicalResolver.stringEscapes(for: databaseType, session: sessionDriver?.sessionLexicalState)
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
        SchemaQualifiedName.render(name: tableName, schema: schema, databaseType: databaseType, quote: quote)
    }

    func buildBaseQuery(
        tableName: String,
        schemaName: String? = nil,
        sortState: SortState? = nil,
        columns: [String] = [],
        selectColumns: [String]? = nil,
        unloadedValues: UnloadedValuePlan? = nil,
        limit: Int = 200,
        offset: Int = 0,
        window: Bool = true
    ) -> String {
        if window, let pluginDriver {
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
        var query = "SELECT \(selectClause(selectColumns, unloadedValues: unloadedValues)) FROM \(quotedTable)"
        appendOrderAndWindow(to: &query, sortState: sortState, columns: columns, limit: limit, offset: offset, window: window)
        return query
    }

    // A dialect is what lets the host write the statement itself, the only kind that can leave its window off.
    var writesSQL: Bool {
        dialect != nil
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
        unloadedValues: UnloadedValuePlan? = nil,
        limit: Int = 200,
        offset: Int = 0,
        window: Bool = true
    ) -> String? {
        // A driver that writes its own SQL takes a raw condition as given, so the boundary check the
        // host's generator applies has to run before the driver is asked.
        if dialect != nil, filters.contains(where: {
            $0.isEnabled && FilterSQLGenerator.refusesRawCondition($0, databaseType: databaseType)
        }) {
            return nil
        }
        // A driver reads a column named like the raw row as a raw condition, so a comparison on such a
        // column is written by the host's generator, or by no one.
        let reachesDriver = !filters.contains { $0.isEnabled && $0.namesRawConditionColumn }
        if window, let pluginDriver, reachesDriver {
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

        guard let dialect else { return nil }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        var query = "SELECT \(selectClause(selectColumns, unloadedValues: unloadedValues)) FROM \(quotedTable)"

        let filterGen = FilterSQLGenerator(
            dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType), databaseType: databaseType,
            stringEscapes: stringEscapes
        )
        guard let whereClause = filterGen.generateWhereClause(
            from: filters.filter { $0.isEnabled },
            logicMode: logicMode
        ) else { return nil }
        if !whereClause.isEmpty {
            query += " \(whereClause)"
        }
        appendOrderAndWindow(to: &query, sortState: sortState, columns: columns, limit: limit, offset: offset, window: window)
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
        unloadedValues: UnloadedValuePlan? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        if let pluginDriver {
            let targetColumns = selectColumns ?? columns
            let sortCols = SortColumnResolver.resolvedIndices(
                for: sortState, displayColumns: columns, targetColumns: targetColumns
            )
            let tuples = BrowseSearchState(pattern: pattern, typeScope: typeScope).pluginQueryFilters
                .map { (column: $0.column, op: $0.op, value: $0.value) }
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
            columns: columns, selectColumns: selectColumns, unloadedValues: unloadedValues,
            limit: limit, offset: offset
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
            dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType), databaseType: databaseType,
            stringEscapes: stringEscapes
        )
        guard let whereClause = filterGen.generateWhereClause(from: activeFilters, logicMode: logicMode) else {
            return nil
        }
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

    private func selectClause(_ selectColumns: [String]?, unloadedValues: UnloadedValuePlan?) -> String {
        guard let selectColumns, !selectColumns.isEmpty else { return "*" }
        if let unloadedValues {
            return unloadedValues.selectList(for: selectColumns, quote: quote)
        }
        return selectColumns.map { quote($0) }.joined(separator: ", ")
    }

    // Without a window only the person's own sort goes in: the default ORDER BY exists for OFFSET ... FETCH.
    private func appendOrderAndWindow(
        to query: inout String,
        sortState: SortState?,
        columns: [String],
        limit: Int,
        offset: Int,
        window: Bool
    ) {
        let orderBy = window
            ? orderByOrOffsetFetchDefault(sortState: sortState, columns: columns)
            : buildOrderByClause(sortState: sortState, columns: columns)
        if let orderBy {
            query += " \(orderBy)"
        }
        if window {
            query += " \(buildPaginationClause(limit: limit, offset: offset))"
        }
    }

    private func buildPaginationClause(limit: Int, offset: Int) -> String {
        guard pagination.allowsSeeking else {
            return "LIMIT \(pagination.clampedRowCount(limit))"
        }
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
