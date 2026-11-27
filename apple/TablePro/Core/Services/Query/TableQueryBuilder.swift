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

    /// A page found past the edge row of the page beside it, where the order is the table's unique key: the
    /// server reads only the rows it returns, so page 5,000 costs what page 1 does. A backward read runs the order
    /// in reverse and the caller flips the rows. The key goes to the driver as bound values, never into the text:
    /// the page can run on another pooled connection, which may read a quote or backslash another way. Nil where a
    /// plugin writes its own pages, a filter cannot be written, or a key value has no exact form; those pages read
    /// at their offset.
    func buildKeysetPageQuery(
        tableName: String,
        schemaName: String? = nil,
        filters: [TableFilter] = [],
        logicMode: FilterLogicMode = .and,
        sortState: SortState,
        columns: [String],
        columnTypes: [ColumnType] = [],
        selectColumns: [String]? = nil,
        unloadedValues: UnloadedValuePlan? = nil,
        limit: Int,
        seek: TableKeysetSeek
    ) -> KeyedPageStatement? {
        guard let dialect, pagination.allowsSeeking, !seek.columns.isEmpty,
              seek.columns.count == seek.columnTypes.count,
              Self.spellsTheSame(sortState.columns.compactMap(\.columnName), seek.columns),
              sortState.columns.allSatisfy({ $0.direction == seek.direction }) else { return nil }
        let enabled = filters.filter(\.isEnabled)
        // A raw condition is the user's own SQL, where a `?` or `$1` would take the key's place.
        guard !enabled.contains(where: \.isRawSQL), !pluginWritesPage(
            tableName: tableName, schemaName: schemaName, filters: enabled, logicMode: logicMode,
            sortState: sortState, columns: columns, columnTypes: columnTypes, selectColumns: selectColumns, limit: limit
        ) else { return nil }

        var conditions: [String] = []
        if !enabled.isEmpty {
            let filterGen = FilterSQLGenerator(
                dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote,
                stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType), databaseType: databaseType,
                stringEscapes: stringEscapes
            )
            guard let whereClause = filterGen.generateWhereClause(from: enabled, logicMode: logicMode) else { return nil }
            if whereClause.hasPrefix("WHERE ") {
                conditions.append("(\(whereClause.dropFirst("WHERE ".count)))")
            }
        }
        var keyValues: [String] = []
        if let key = seek.key {
            guard key.count == seek.columns.count else { return nil }
            for (value, type) in zip(key, seek.columnTypes) {
                guard let bound = Self.keyValue(value, type: type) else { return nil }
                keyValues.append(bound)
            }
            conditions.append(seekCondition(seek))
        }

        let projection = selectClause(selectColumns, unloadedValues: unloadedValues)
        var query = "SELECT \(projection) FROM \(qualifiedTable(tableName, schema: schemaName))"
        if !conditions.isEmpty {
            query += " WHERE " + conditions.joined(separator: " AND ")
        }
        var order = sortState
        if seek.readsBackward {
            order.columns = order.columns.map {
                SortColumn(columnIndex: $0.columnIndex, direction: $0.direction.opposite, columnName: $0.columnName)
            }
        }
        guard let orderBy = buildOrderByClause(sortState: order, columns: columns) else { return nil }
        query += " \(orderBy) \(buildPaginationClause(limit: limit, offset: 0))"
        return KeyedPageStatement(sql: query, keyValues: keyValues, readsBackward: seek.readsBackward)
    }

    // Swift's `==` joins NFC and NFD spellings of a name, which PostgreSQL and SQLite keep as two columns.
    static func spellsTheSame(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }
    }

    // A row value compares column by column, so one comparison seeks a composite key in its own index order.
    private func seekCondition(_ seek: TableKeysetSeek) -> String {
        let forward = (seek.direction == .ascending) != seek.readsBackward
        let comparison = forward ? ">" : "<"
        let quoted = seek.columns.map { quote($0) }
        let markers = seek.columns.indices.map { placeholder(at: $0) }
        guard quoted.count > 1 else { return "\(quoted[0]) \(comparison) \(markers[0])" }
        return "(\(quoted.joined(separator: ", "))) \(comparison) (\(markers.joined(separator: ", ")))"
    }

    // The key's markers are the statement's only ones, so they number from 1.
    private func placeholder(at index: Int) -> String {
        let style = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle ?? .questionMark
        switch style {
        case .questionMark: return "?"
        case .dollar: return "$\(index + 1)"
        }
    }

    // Only a value that round-trips exactly and compares in the order the page sorts by: a float printed as text can
    // land beside the row it came from, a number compared as text orders 10 before 9, and MySQL sorts an ENUM by its
    // position but compares it with a string by its text.
    static func keyValue(_ value: PluginCellValue, type: ColumnType?) -> String? {
        guard case .text(let text) = value, let type else { return nil }
        switch type {
        case .integer:
            return RowValueCopyFormatter.isIntegerLiteral(text) ? text : nil
        // A SQLite NUMERIC column keeps a REAL near a whole number, which an older SQLite prints as `1.0`; past that
        // edge `> 1.0` reads the row again. Digits alone are an INTEGER there, and exact as MySQL's double too.
        case .decimal(let rawType):
            let raw = rawType?.uppercased() ?? ""
            guard !["FLOAT", "REAL", "DOUBLE"].contains(where: raw.contains) else { return nil }
            return isWholeNumber(text) ? text : nil
        // A SQLite column declared with no type, or ANY in a STRICT table, keeps an integer as an integer, which sorts
        // below every string.
        case .text(let rawType) where (rawType ?? "").isEmpty || rawType?.uppercased() == "ANY":
            return nil
        // A SQLite column of a date or other non-text type keeps a number-like value as a number, a REAL printed
        // rounded. Standard escaping drops a NUL and SQLite keeps one in text, so that key is refused as before.
        case .text, .date, .datetime:
            guard Double(text) == nil || isWholeNumber(text), !text.unicodeScalars.contains("\0") else { return nil }
            return text
        // A MySQL TIMESTAMP prints in the session's zone, where the hour a clock turns back reads twice.
        case .timestamp, .boolean, .blob, .json, .enumType, .set, .spatial, .vector, .array:
            return nil
        }
    }

    // Digits alone, at most 15 of them: SQLite stores those as an INTEGER, and a double holds them exactly.
    private static func isWholeNumber(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let digits = scalars.first == "-" ? scalars.dropFirst() : scalars[...]
        return (1...15).contains(digits.count) && digits.allSatisfy { ("0"..."9").contains($0) }
    }

    // What `buildBaseQuery` and `buildFilteredQuery` would hand the plugin, asked the same way.
    private func pluginWritesPage(
        tableName: String,
        schemaName: String?,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        sortState: SortState,
        columns: [String],
        columnTypes: [ColumnType],
        selectColumns: [String]?,
        limit: Int
    ) -> Bool {
        guard let pluginDriver else { return false }
        let targetColumns = selectColumns ?? columns
        let sortCols = SortColumnResolver.resolvedIndices(
            for: sortState, displayColumns: columns, targetColumns: targetColumns
        )
        guard !filters.isEmpty else {
            return pluginDriver.buildBrowseQuery(
                table: tableName, schema: schemaName, sortColumns: sortCols,
                columns: targetColumns, limit: limit, offset: 0
            ) != nil
        }
        guard !filters.contains(where: \.namesRawConditionColumn) else { return false }
        return pluginDriver.buildFilteredQuery(
            table: tableName, schema: schemaName,
            queryFilters: filters.filter { !$0.columnName.isEmpty }.map(\.asPluginQueryFilter),
            logicMode: logicMode == .and ? "and" : "or",
            sortColumns: sortCols, columns: targetColumns, limit: limit, offset: 0,
            columnKinds: pluginColumnKinds(columns: columns, columnTypes: columnTypes)
        ) != nil
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
        guard let whereClause = countWhereClause(
            filters: filters, logicMode: logicMode, columns: columns, columnTypes: columnTypes
        ) else { return nil }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        guard !whereClause.isEmpty else {
            return "SELECT COUNT(*) FROM \(quotedTable)"
        }
        return "SELECT COUNT(*) FROM \(quotedTable) \(whereClause)"
    }

    // Reads at most `limit` rows, so a view or an unanalyzed table costs a bounded read. The alias has no AS: Oracle refuses one.
    // A plugin that writes its own pages may not speak LIMIT (Teradata), so only OFFSET FETCH is taken as its syntax.
    func buildCappedCountQuery(
        tableName: String,
        schemaName: String? = nil,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        limit: Int
    ) -> String? {
        guard pluginDriver == nil || dialect?.paginationStyle == .offsetFetch else { return nil }
        guard let whereClause = countWhereClause(
            filters: filters, logicMode: logicMode, columns: columns, columnTypes: columnTypes
        ) else { return nil }

        var rows = "SELECT 1 AS row_marker FROM \(qualifiedTable(tableName, schema: schemaName))"
        if !whereClause.isEmpty {
            rows += " \(whereClause)"
        }
        appendOrderAndWindow(to: &rows, sortState: nil, columns: columns, limit: limit, offset: 0, window: true)
        return "SELECT COUNT(*) FROM (\(rows)) capped_rows"
    }

    private func countWhereClause(
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        columns: [String],
        columnTypes: [ColumnType]
    ) -> String? {
        guard let dialect else { return nil }
        let filterGen = FilterSQLGenerator(
            dialect: dialect, columns: columns, columnTypes: columnTypes, quoteIdentifier: dialectQuote,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType), databaseType: databaseType,
            stringEscapes: stringEscapes
        )
        return filterGen.generateWhereClause(from: filters.filter { $0.isEnabled }, logicMode: logicMode)
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

/// The statement one page move sends, with the edge row's key as its bound values. Nothing keeps it past that run.
struct KeyedPageStatement: Equatable, Sendable {
    let sql: String
    let keyValues: [String]
    let readsBackward: Bool
}

/// The table's unique key in its page order, and the edge row a keyed page is read past.
struct TableKeysetSeek: Equatable, Sendable {
    let columns: [String]
    let columnTypes: [ColumnType?]
    let direction: SortDirection
    // Nil for the last page, read backward from the end.
    let key: [PluginCellValue]?
    let readsBackward: Bool
}
