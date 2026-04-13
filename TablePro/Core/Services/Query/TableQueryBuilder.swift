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
        limit: Int = 200,
        offset: Int = 0,
        columnExclusions: [ColumnExclusion] = []
    ) -> String {
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            if let result = pluginDriver.buildBrowseQuery(
                table: tableName, sortColumns: sortCols,
                columns: columns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        let selectClause = buildSelectClause(columns: columns, exclusions: columnExclusions)
        var query = "SELECT \(selectClause) FROM \(quotedTable)"

        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
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
        limit: Int = 200,
        offset: Int = 0,
        columnExclusions: [ColumnExclusion] = []
    ) -> String {
        if let pluginDriver {
            let sortCols = sortColumnsAsTuples(sortState)
            let filterTuples = filters
                .filter { $0.isEnabled && !$0.columnName.isEmpty }
                .map { filter in
                    let value: String
                    if filter.filterOperator == .between, let second = filter.secondValue {
                        value = "\(filter.value),\(second)"
                    } else {
                        value = filter.value
                    }
                    return (filter.columnName, filter.filterOperator.rawValue, value)
                }
            if let result = pluginDriver.buildFilteredQuery(
                table: tableName, filters: filterTuples,
                logicMode: logicMode == .and ? "and" : "or",
                sortColumns: sortCols, columns: columns, limit: limit, offset: offset
            ) {
                return result
            }
        }

        let quotedTable = qualifiedTable(tableName, schema: schemaName)
        let selectClause = buildSelectClause(columns: columns, exclusions: columnExclusions)
        var query = "SELECT \(selectClause) FROM \(quotedTable)"

        if let dialect {
            let activeFilters = filters.filter { $0.isEnabled }
            let filterGen = FilterSQLGenerator(dialect: dialect, quoteIdentifier: dialectQuote)
            let whereClause = filterGen.generateWhereClause(from: activeFilters, logicMode: logicMode)
            if !whereClause.isEmpty {
                query += " \(whereClause)"
            }
        }

        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            query += " \(orderBy)"
        }

        query += " \(buildPaginationClause(limit: limit, offset: offset))"
        return query
    }

    func buildSortedQuery(
        baseQuery: String,
        columnName: String,
        ascending: Bool
    ) -> String {
        var query = removeOrderBy(from: baseQuery)
        let direction = ascending ? "ASC" : "DESC"
        let quotedColumn = quote(columnName)
        let orderByClause = "ORDER BY \(quotedColumn) \(direction)"

        if let limitRange = query.range(of: "LIMIT", options: .caseInsensitive) {
            let beforeLimit = query[..<limitRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let limitClause = query[limitRange.lowerBound...]
            query = "\(beforeLimit) \(orderByClause) \(limitClause)"
        } else if let offsetRange = query.range(of: "OFFSET", options: .caseInsensitive) {
            let beforeOffset = query[..<offsetRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let offsetClause = query[offsetRange.lowerBound...]
            query = "\(beforeOffset) \(orderByClause) \(offsetClause)"
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(";") {
                query = String(trimmed.dropLast()) + " \(orderByClause);"
            } else {
                query = "\(trimmed) \(orderByClause)"
            }
        }

        return query
    }

    func buildMultiSortQuery(
        baseQuery: String,
        sortState: SortState,
        columns: [String]
    ) -> String {
        var query = removeOrderBy(from: baseQuery)

        if let orderBy = buildOrderByClause(sortState: sortState, columns: columns) {
            if let limitRange = query.range(of: "LIMIT", options: .caseInsensitive) {
                let beforeLimit = query[..<limitRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let limitClause = query[limitRange.lowerBound...]
                query = "\(beforeLimit) \(orderBy) \(limitClause)"
            } else if let offsetRange = query.range(of: "OFFSET", options: .caseInsensitive) {
                let beforeOffset = query[..<offsetRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let offsetClause = query[offsetRange.lowerBound...]
                query = "\(beforeOffset) \(orderBy) \(offsetClause)"
            } else {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix(";") {
                    query = String(trimmed.dropLast()) + " \(orderBy);"
                } else {
                    query = "\(trimmed) \(orderBy)"
                }
            }
        }

        return query
    }

    // MARK: - Private Helpers

    private func buildSelectClause(columns: [String], exclusions: [ColumnExclusion]) -> String {
        guard !exclusions.isEmpty, !columns.isEmpty else { return "*" }

        let exclusionMap = Dictionary(exclusions.map { ($0.columnName, $0.placeholderExpression) }) { _, last in last }

        return columns.map { col in
            if let placeholder = exclusionMap[col] {
                return "\(placeholder) AS \(quote(col))"
            }
            return quote(col)
        }.joined(separator: ", ")
    }

    private func buildPaginationClause(limit: Int, offset: Int) -> String {
        if let dialect, dialect.paginationStyle == .offsetFetch {
            return "OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        }
        return "LIMIT \(limit) OFFSET \(offset)"
    }

    private func sortColumnsAsTuples(_ sortState: SortState?) -> [(columnIndex: Int, ascending: Bool)] {
        sortState?.columns.compactMap { sortCol -> (columnIndex: Int, ascending: Bool)? in
            guard sortCol.columnIndex >= 0 else { return nil }
            return (sortCol.columnIndex, sortCol.direction == .ascending)
        } ?? []
    }

    private func buildOrderByClause(sortState: SortState?, columns: [String]) -> String? {
        guard let state = sortState, state.isSorting else { return nil }

        let parts = state.columns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = columns[sortCol.columnIndex]
            let direction = sortCol.direction == .ascending ? "ASC" : "DESC"
            let quotedColumn = quote(columnName)
            return "\(quotedColumn) \(direction)"
        }

        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    private func removeOrderBy(from query: String) -> String {
        var result = query

        guard let orderByRange = result.range(of: "ORDER BY", options: [.caseInsensitive, .backwards]) else {
            return result
        }

        let afterOrderBy = result[orderByRange.upperBound...]

        if let limitRange = afterOrderBy.range(of: "LIMIT", options: .caseInsensitive) {
            let beforeOrderBy = result[..<orderByRange.lowerBound]
            let limitClause = result[limitRange.lowerBound...]
            result = String(beforeOrderBy) + String(limitClause)
        } else if let offsetRange = afterOrderBy.range(of: "OFFSET", options: .caseInsensitive) {
            let beforeOrderBy = result[..<orderByRange.lowerBound]
            let offsetClause = result[offsetRange.lowerBound...]
            result = String(beforeOrderBy) + String(offsetClause)
        } else if afterOrderBy.range(of: ";") != nil {
            result = String(result[..<orderByRange.lowerBound]) + ";"
        } else {
            result = String(result[..<orderByRange.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespaces)
    }
}
