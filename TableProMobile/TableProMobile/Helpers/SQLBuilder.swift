import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery

nonisolated enum SQLBuilder {
    static func quoteIdentifier(_ name: String, for type: DatabaseType) -> String {
        switch type {
        case .mysql, .mariadb:
            return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql, .redshift:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        case .mssql:
            return "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        default:
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    static func paginationClause(orderBy: String, limit: Int, offset: Int, for type: DatabaseType) -> String {
        switch type {
        case .mssql:
            let order = orderBy.isEmpty ? "ORDER BY (SELECT NULL)" : orderBy
            return "\(order) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        case .oracle:
            let order = orderBy.isEmpty ? "ORDER BY 1" : orderBy
            return "\(order) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        default:
            let trailing = "LIMIT \(limit) OFFSET \(offset)"
            return orderBy.isEmpty ? trailing : "\(orderBy) \(trailing)"
        }
    }

    static func buildCount(table: String, type: DatabaseType) -> String {
        let quoted = quoteIdentifier(table, for: type)
        return "SELECT COUNT(*) FROM \(quoted)"
    }

    static func buildSelect(table: String, type: DatabaseType, limit: Int, offset: Int) -> String {
        let quoted = quoteIdentifier(table, for: type)
        let pagination = paginationClause(orderBy: "", limit: limit, offset: offset, for: type)
        return "SELECT * FROM \(quoted) \(pagination)"
    }

    static func buildDelete(
        table: String,
        type: DatabaseType,
        driver: any DatabaseDriver,
        primaryKeys: [(column: String, value: String)]
    ) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        let predicate = primaryKeys.map {
            "\(quoteIdentifier($0.column, for: type)) = '\(driver.escapeStringLiteral($0.value))'"
        }.joined(separator: " AND ")
        return "DELETE FROM \(quotedTable) WHERE \(predicate)"
    }

    static func buildUpdate(
        table: String,
        type: DatabaseType,
        driver: any DatabaseDriver,
        changes: [(column: String, value: String?)],
        primaryKeys: [(column: String, value: String)]
    ) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        let assignments = changes.map { col, val in
            let qcol = quoteIdentifier(col, for: type)
            if let val { return "\(qcol) = '\(driver.escapeStringLiteral(val))'" }
            return "\(qcol) = NULL"
        }.joined(separator: ", ")
        let predicate = primaryKeys.map {
            "\(quoteIdentifier($0.column, for: type)) = '\(driver.escapeStringLiteral($0.value))'"
        }.joined(separator: " AND ")
        return "UPDATE \(quotedTable) SET \(assignments) WHERE \(predicate)"
    }

    static func buildInsert(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        values: [String?]
    ) -> String {
        let qualifiedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        let cols = columns.map { quoteIdentifier($0, for: type) }.joined(separator: ", ")
        let vals = values.map { val in
            if let val { return "'\(driver.escapeStringLiteral(val))'" }
            return "NULL"
        }.joined(separator: ", ")
        return "INSERT INTO \(qualifiedTable) (\(cols)) VALUES (\(vals))"
    }

    static func qualifiedIdentifier(table: String, schema: String?, for type: DatabaseType) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        guard let schema, !schema.isEmpty else { return quotedTable }
        return "\(quoteIdentifier(schema, for: type)).\(quotedTable)"
    }

    static func buildSelect(
        table: String, type: DatabaseType,
        sortState: SortState,
        limit: Int, offset: Int
    ) -> String {
        let quoted = quoteIdentifier(table, for: type)
        let orderBy = buildOrderByClause(sortState, for: type)
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        return "SELECT * FROM \(quoted) \(pagination)"
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
        let pagination = paginationClause(orderBy: "", limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
        return sql
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
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
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
        let orderBy = buildOrderByClause(sortState, for: type)
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
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
        let likeEscape: String = dialect.likeEscapeStyle == .explicit ? " ESCAPE '!'" : ""

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
            case .oracle:
                castExpr = "CAST(\(quotedCol) AS VARCHAR2(4000))"
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
        if dialect.likeEscapeStyle == .explicit {
            result = result
                .replacingOccurrences(of: "!", with: "!!")
                .replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_")
        } else {
            if dialect.requiresBackslashEscaping {
                result = result.replacingOccurrences(of: "\\", with: "\\\\")
            }
            result = result.replacingOccurrences(of: "%", with: "\\%")
            result = result.replacingOccurrences(of: "_", with: "\\_")
        }
        return result
    }

    private static func buildOrderByClause(_ sortState: SortState, for type: DatabaseType) -> String {
        guard sortState.isSorting else { return "" }
        let clauses = sortState.columns.map { col in
            "\(quoteIdentifier(col.name, for: type)) \(col.ascending ? "ASC" : "DESC")"
        }
        return "ORDER BY " + clauses.joined(separator: ", ")
    }

    static func caseSensitivityStyle(for type: DatabaseType) -> SQLDialectDescriptor.CaseSensitivityStyle {
        dialectDescriptor(for: type).caseSensitivityStyle
    }

    /// Mirrors what each driver's plugin declares on the Mac, because iOS links its drivers
    /// directly and has no plugin bundle to ask. The default arm is the trap: an omitted type gets
    /// `caseSensitivityStyle` `.unsupported`, which resolves to plain `LIKE` and to a case
    /// sensitivity toggle the UI will not offer, so a filter silently returns fewer rows than the
    /// same filter on the Mac. `SQLDialectParityTests` is what stops a new driver landing here
    /// without an arm.
    private static func dialectDescriptor(for type: DatabaseType) -> SQLDialectDescriptor {
        switch type {
        case .mysql, .mariadb:
            return SQLDialectDescriptor(
                identifierQuote: "`",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .implicit,
                requiresBackslashEscaping: true,
                caseSensitivityStyle: .collationDefined
            )
        case .postgresql:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .ilikeOperator
            )
        case .redshift:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .caseFoldFunction
            )
        case .mssql:
            return SQLDialectDescriptor(
                identifierQuote: "[",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .collationDefined
            )
        case .oracle:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .caseFoldFunction
            )
        case .sqlite:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .collationDefined
            )
        case .duckdb:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                regexSyntax: .regexpMatches,
                booleanLiteralStyle: .truefalse,
                likeEscapeStyle: .explicit,
                paginationStyle: .limit,
                caseSensitivityStyle: .ilikeOperator
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
