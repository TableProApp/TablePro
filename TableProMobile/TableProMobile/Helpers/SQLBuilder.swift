//
//  SQLBuilder.swift
//  TableProMobile
//

import Foundation
import TableProModels
import TableProPluginKit
import TableProQuery

enum SQLBuilder {
    static func quoteIdentifier(_ name: String, for type: DatabaseType) -> String {
        switch type {
        case .mysql, .mariadb:
            return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql, .redshift:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        default:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    static func escapeString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{1a}", with: "\\Z")
            .replacingOccurrences(of: "'", with: "''")
    }

    static func buildCount(table: String, type: DatabaseType) -> String {
        let quoted = quoteIdentifier(table, for: type)
        return "SELECT COUNT(*) FROM \(quoted)"
    }

    static func buildSelect(table: String, type: DatabaseType, limit: Int, offset: Int) -> String {
        let quoted = quoteIdentifier(table, for: type)
        return "SELECT * FROM \(quoted) LIMIT \(limit) OFFSET \(offset)"
    }

    static func buildDelete(
        table: String,
        type: DatabaseType,
        primaryKeys: [(column: String, value: String)]
    ) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        let where_ = primaryKeys.map {
            "\(quoteIdentifier($0.column, for: type)) = '\(escapeString($0.value))'"
        }.joined(separator: " AND ")
        return "DELETE FROM \(quotedTable) WHERE \(where_)"
    }

    static func buildUpdate(
        table: String,
        type: DatabaseType,
        changes: [(column: String, value: String?)],
        primaryKeys: [(column: String, value: String)]
    ) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        let set_ = changes.map { col, val in
            let qcol = quoteIdentifier(col, for: type)
            if let val { return "\(qcol) = '\(escapeString(val))'" }
            return "\(qcol) = NULL"
        }.joined(separator: ", ")
        let where_ = primaryKeys.map {
            "\(quoteIdentifier($0.column, for: type)) = '\(escapeString($0.value))'"
        }.joined(separator: " AND ")
        return "UPDATE \(quotedTable) SET \(set_) WHERE \(where_)"
    }

    static func buildInsert(
        table: String,
        type: DatabaseType,
        columns: [String],
        values: [String?]
    ) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        let cols = columns.map { quoteIdentifier($0, for: type) }.joined(separator: ", ")
        let vals = values.map { val in
            if let val { return "'\(escapeString(val))'" }
            return "NULL"
        }.joined(separator: ", ")
        return "INSERT INTO \(quotedTable) (\(cols)) VALUES (\(vals))"
    }

    static func buildSelect(
        table: String, type: DatabaseType,
        sortState: SortState,
        limit: Int, offset: Int
    ) -> String {
        let quoted = quoteIdentifier(table, for: type)
        let orderBy = buildOrderByClause(sortState, for: type)
        return "SELECT * FROM \(quoted) \(orderBy) LIMIT \(limit) OFFSET \(offset)"
            .replacingOccurrences(of: "  ", with: " ")
    }

    static func buildFilteredSelect(
        table: String, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode,
        limit: Int, offset: Int
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = FilterSQLGenerator(dialect: dialect)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        let quoted = quoteIdentifier(table, for: type)
        if whereClause.isEmpty {
            return "SELECT * FROM \(quoted) LIMIT \(limit) OFFSET \(offset)"
        }
        return "SELECT * FROM \(quoted) \(whereClause) LIMIT \(limit) OFFSET \(offset)"
    }

    static func buildFilteredSelect(
        table: String, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode,
        sortState: SortState,
        limit: Int, offset: Int
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = FilterSQLGenerator(dialect: dialect)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        let orderBy = buildOrderByClause(sortState, for: type)
        let quoted = quoteIdentifier(table, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        if !orderBy.isEmpty { sql += " \(orderBy)" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return sql
    }

    static func buildFilteredCount(
        table: String, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = FilterSQLGenerator(dialect: dialect)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        let quoted = quoteIdentifier(table, for: type)
        if whereClause.isEmpty {
            return "SELECT COUNT(*) FROM \(quoted)"
        }
        return "SELECT COUNT(*) FROM \(quoted) \(whereClause)"
    }

    // MARK: - Search

    static func buildSearchSelect(
        table: String, type: DatabaseType,
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter] = [], logicMode: FilterLogicMode = .and,
        sortState: SortState = SortState(),
        limit: Int, offset: Int
    ) -> String {
        let quoted = quoteIdentifier(table, for: type)
        let whereClause = buildSearchWhereClause(
            searchText: searchText, searchColumns: searchColumns,
            filters: filters, logicMode: logicMode, type: type
        )
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        let orderBy = buildOrderByClause(sortState, for: type)
        if !orderBy.isEmpty { sql += " \(orderBy)" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return sql
    }

    static func buildSearchCount(
        table: String, type: DatabaseType,
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter] = [], logicMode: FilterLogicMode = .and
    ) -> String {
        let quoted = quoteIdentifier(table, for: type)
        let whereClause = buildSearchWhereClause(
            searchText: searchText, searchColumns: searchColumns,
            filters: filters, logicMode: logicMode, type: type
        )
        var sql = "SELECT COUNT(*) FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        return sql
    }

    private static func buildSearchWhereClause(
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter], logicMode: FilterLogicMode,
        type: DatabaseType
    ) -> String {
        var whereParts: [String] = []

        let searchClause = buildSearchClause(searchText: searchText, columns: searchColumns, type: type)
        if !searchClause.isEmpty {
            whereParts.append(searchClause)
        }

        if let filterConditions = filterConditions(filters: filters, logicMode: logicMode, type: type) {
            whereParts.append("(\(filterConditions))")
        }

        guard !whereParts.isEmpty else { return "" }
        return "WHERE " + whereParts.joined(separator: " AND ")
    }

    private static func filterConditions(
        filters: [TableFilter], logicMode: FilterLogicMode, type: DatabaseType
    ) -> String? {
        let dialect = dialectDescriptor(for: type)
        let generator = FilterSQLGenerator(dialect: dialect)
        let clause = generator.generateWhereClause(from: filters, logicMode: logicMode)
        guard !clause.isEmpty else { return nil }
        let wherePrefix = "WHERE "
        return clause.hasPrefix(wherePrefix)
            ? String(clause.dropFirst(wherePrefix.count))
            : clause
    }

    private static func buildSearchClause(
        searchText: String, columns: [ColumnInfo], type: DatabaseType
    ) -> String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !columns.isEmpty else { return "" }

        let dialect = dialectDescriptor(for: type)
        let pattern = escapeLikePattern(trimmed, dialect: dialect)
        let likeEscape: String = dialect.likeEscapeStyle == .explicit ? " ESCAPE '\\'" : ""

        let conditions = columns.map { col -> String in
            let quotedCol = quoteIdentifier(col.name, for: type)
            let castExpr: String
            switch type {
            case .mysql, .mariadb:
                castExpr = "CAST(\(quotedCol) AS CHAR)"
            case .postgresql, .redshift:
                castExpr = "CAST(\(quotedCol) AS TEXT)"
            case .mssql:
                castExpr = "CAST(\(quotedCol) AS NVARCHAR(MAX))"
            case .clickhouse:
                castExpr = "toString(\(quotedCol))"
            default:
                castExpr = "CAST(\(quotedCol) AS TEXT)"
            }
            let likeOp = (type == .postgresql || type == .redshift) ? "ILIKE" : "LIKE"
            return "\(castExpr) \(likeOp) '%\(pattern)%'\(likeEscape)"
        }

        return "(\(conditions.joined(separator: " OR ")))"
    }

    private static func escapeLikePattern(_ value: String, dialect: SQLDialectDescriptor) -> String {
        var result = value
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\0", with: "")
        if dialect.requiresBackslashEscaping {
            result = result.replacingOccurrences(of: "\\", with: "\\\\")
        }
        result = result.replacingOccurrences(of: "%", with: "\\%")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        return result
    }

    private static func buildOrderByClause(_ sortState: SortState, for type: DatabaseType) -> String {
        guard sortState.isSorting else { return "" }
        let clauses = sortState.columns.map { col in
            "\(quoteIdentifier(col.name, for: type)) \(col.ascending ? "ASC" : "DESC")"
        }
        return "ORDER BY " + clauses.joined(separator: ", ")
    }

    private static func dialectDescriptor(for type: DatabaseType) -> SQLDialectDescriptor {
        switch type {
        case .mysql, .mariadb:
            return SQLDialectDescriptor(
                identifierQuote: "`",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .implicit,
                requiresBackslashEscaping: true
            )
        case .postgresql, .redshift:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit
            )
        default:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: []
            )
        }
    }
}
