import Foundation
import TableProDatabase
import TableProModels
import TableProMSSQLCore
import TableProPluginKit
import TableProQuery
import TableProSQLGrammar
import TableProSQLQuoting

nonisolated enum SQLBuilder {
    static func stringLiteral(_ value: String, for type: DatabaseType, driver: any DatabaseDriver) -> String {
        if type == .mssql { return MSSQLStringLiteral.quoted(value) }
        return "'\(driver.escapeStringLiteral(value))'"
    }

    static func speaksMySQLDialect(_ type: DatabaseType) -> Bool {
        SqlDialect.from(databaseTypeId: type.rawValue) == .mysql
    }

    static func quoteIdentifier(_ name: String, for type: DatabaseType) -> String {
        if speaksMySQLDialect(type) {
            return SQLQuoting.identifier(name, quote: .backtick)
        }
        switch type {
        case .mssql:
            return SQLQuoting.identifier(name, quote: .bracket)
        case .clickhouse:
            return clickHouseQuotedIdentifier(name)
        default:
            return SQLQuoting.identifier(name)
        }
    }

    static func paginationClause(orderBy: String, limit: Int, offset: Int, for type: DatabaseType) -> String {
        switch type {
        case .mssql:
            let order = orderBy.isEmpty ? "ORDER BY (SELECT NULL)" : orderBy
            return "\(order) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        // No ORDER BY: `ORDER BY 1` fails with ORA-22848 when the first column is a LOB.
        case .oracle:
            let trailing = "OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
            return orderBy.isEmpty ? trailing : "\(orderBy) \(trailing)"
        default:
            let trailing = "LIMIT \(limit) OFFSET \(offset)"
            return orderBy.isEmpty ? trailing : "\(orderBy) \(trailing)"
        }
    }

    static func buildCount(table: String, schema: String?, type: DatabaseType) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        return "SELECT COUNT(*) FROM \(quoted)"
    }

    static func buildSelect(table: String, schema: String?, type: DatabaseType, limit: Int, offset: Int) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let pagination = paginationClause(orderBy: "", limit: limit, offset: offset, for: type)
        return "SELECT * FROM \(quoted) \(pagination)"
    }

    // Every pair of a composite key is matched: one column alone can return another tenant's row.
    static func buildSingleRowLookup(
        table: String,
        schema: String?,
        key: [(column: String, value: String)],
        columns: [ColumnInfo],
        type: DatabaseType,
        driver: any DatabaseDriver
    ) -> String {
        let quotedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        let predicate = key.isEmpty ? "1 = 0" : keyPredicate(key, columns: columns, type: type, driver: driver)
        let pagination = paginationClause(orderBy: "", limit: 1, offset: 0, for: type)
        return "SELECT * FROM \(quotedTable) WHERE \(predicate) \(pagination)"
    }

    // The literal rule the table browser's filter uses, so a row the lookup finds is the row Open Table lists.
    // Text goes through the driver's escaper: on MySQL a backslash escapes the next quote, so a hand-doubled
    // `a\' OR 1=1 -- ` gets out. With `uniqueIn`, a key that matches either way SQLite stores it also has to
    // name a single row of that table, checked inside the statement so a row stored meanwhile cannot join it.
    static func keyPredicate(
        _ key: [(column: String, value: String)],
        columns: [ColumnInfo],
        type: DatabaseType,
        driver: any DatabaseDriver,
        uniqueIn quotedTable: String? = nil
    ) -> String {
        let predicate = key.map { pair in
            let column = quoteIdentifier(pair.column, for: type)
            let info = FilterColumnKind.column(named: pair.column, in: columns)
            switch FilterColumnKind.keyLiteral(pair.value, column: info, databaseType: type) {
            case .number(let value):
                return "\(column) = \(value)"
            case .text(let value):
                let literal = stringLiteral(value, for: type, driver: driver)
                guard type == .mssql, MSSQLRowMatch.comparesNarrowText(typeName: info?.typeName) else {
                    return "\(column) = \(literal)"
                }
                return "\(column) = \(literal) AND \(MSSQLRowMatch.exactText(column, equals: literal))"
            case .numberOrText(let value):
                // CAST is the text the grid read, so a REAL another spelling of the same number parses to stays out.
                return "\(column) IN (\(value), '\(value)') AND CAST(\(column) AS TEXT) = '\(value)'"
            }
        }.joined(separator: " AND ")
        guard let quotedTable, keyMatchesEitherWay(key, columns: columns, type: type) else { return predicate }
        return "\(predicate) AND (SELECT COUNT(*) FROM \(quotedTable) WHERE \(predicate)) = 1"
    }

    // The one case where a key can name two rows: integer 5 and text '5' in a SQLite column with no type.
    static func keyMatchesEitherWay(_ key: [(column: String, value: String)], columns: [ColumnInfo], type: DatabaseType) -> Bool {
        key.contains { pair in
            let info = FilterColumnKind.column(named: pair.column, in: columns)
            guard case .numberOrText = FilterColumnKind.keyLiteral(pair.value, column: info, databaseType: type) else {
                return false
            }
            return true
        }
    }

    // `session` is what the driver last reported, `DatabaseDriver.settledLexicalFacts`.
    static func filterGenerator(
        dialect: SQLDialectDescriptor,
        type: DatabaseType,
        session: SQLSessionLexicalFacts? = nil
    ) -> FilterSQLGenerator {
        FilterSQLGenerator(
            dialect: dialect,
            databaseType: type,
            quoteIdentifier: { quoteIdentifier($0, for: type) },
            session: session
        )
    }

    static func buildKeyMatchCount(
        table: String,
        schema: String?,
        key: [(column: String, value: String)],
        columns: [ColumnInfo],
        type: DatabaseType,
        driver: any DatabaseDriver
    ) -> String {
        let quotedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        return "SELECT COUNT(*) FROM \(quotedTable) WHERE \(keyPredicate(key, columns: columns, type: type, driver: driver))"
    }

    static func buildDelete(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        primaryKeys: [(column: String, value: String)],
        columns: [ColumnInfo]
    ) -> String {
        let quotedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        let predicate = keyPredicate(primaryKeys, columns: columns, type: type, driver: driver, uniqueIn: quotedTable)
        return "DELETE FROM \(quotedTable) WHERE \(predicate)"
    }

    static func buildUpdate(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        changes: [(column: String, value: String?)],
        primaryKeys: [(column: String, value: String)],
        columns: [ColumnInfo]
    ) -> String {
        let quotedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        let assignments = changes.map { col, val in
            let qcol = quoteIdentifier(col, for: type)
            if let val { return "\(qcol) = \(stringLiteral(val, for: type, driver: driver))" }
            return "\(qcol) = NULL"
        }.joined(separator: ", ")
        let predicate = keyPredicate(primaryKeys, columns: columns, type: type, driver: driver, uniqueIn: quotedTable)
        return "UPDATE \(quotedTable) SET \(assignments) WHERE \(predicate)"
    }

    static func buildInsert(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        values: [String?]
    ) -> String? {
        let qualifiedTable = qualifiedIdentifier(table: table, schema: schema, for: type)
        guard !columns.isEmpty else {
            return buildAllDefaultsInsert(qualifiedTable: qualifiedTable, for: type)
        }
        let cols = columns.map { quoteIdentifier($0, for: type) }.joined(separator: ", ")
        let vals = values.map { val in
            if let val { return stringLiteral(val, for: type, driver: driver) }
            return "NULL"
        }.joined(separator: ", ")
        return "INSERT INTO \(qualifiedTable) (\(cols)) VALUES (\(vals))"
    }

    // Oracle accepts neither `() VALUES ()` nor `DEFAULT VALUES`, so it gets no statement.
    static func buildAllDefaultsInsert(qualifiedTable: String, for type: DatabaseType) -> String? {
        if speaksMySQLDialect(type) {
            return "INSERT INTO \(qualifiedTable) () VALUES ()"
        }
        let takesDefaultValues = type.isSQLiteFamily || [.postgresql, .redshift, .mssql, .duckdb].contains(type)
        return takesDefaultValues ? "INSERT INTO \(qualifiedTable) DEFAULT VALUES" : nil
    }

    // SQLite has no TRUNCATE statement; a DELETE with no WHERE is its truncate.
    static func truncateStatement(table: String, schema: String?, type: DatabaseType) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        return type.isSQLiteFamily ? "DELETE FROM \(quoted)" : "TRUNCATE TABLE \(quoted)"
    }

    static func supportsAllDefaultsInsert(_ type: DatabaseType) -> Bool {
        buildAllDefaultsInsert(qualifiedTable: "t", for: type) != nil
    }

    static func qualifiedIdentifier(table: String, schema: String?, for type: DatabaseType) -> String {
        let quotedTable = quoteIdentifier(table, for: type)
        guard let schema, !schema.isEmpty else { return quotedTable }
        return "\(quoteIdentifier(schema, for: type)).\(quotedTable)"
    }

    static func buildSelect(
        table: String, schema: String?, type: DatabaseType,
        sortState: SortState,
        limit: Int, offset: Int
    ) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let orderBy = buildOrderByClause(sortState, for: type)
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        return "SELECT * FROM \(quoted) \(pagination)"
    }

    static func buildFilteredSelect(
        table: String, schema: String?, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode,
        columns: [ColumnInfo] = [],
        session: SQLSessionLexicalFacts? = nil,
        limit: Int, offset: Int
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = filterGenerator(dialect: dialect, type: type, session: session)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode, columns: columns)
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let pagination = paginationClause(orderBy: "", limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
        return sql
    }

    static func buildFilteredSelect(
        table: String, schema: String?, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode,
        columns: [ColumnInfo] = [],
        session: SQLSessionLexicalFacts? = nil,
        sortState: SortState,
        limit: Int, offset: Int
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = filterGenerator(dialect: dialect, type: type, session: session)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode, columns: columns)
        let orderBy = buildOrderByClause(sortState, for: type)
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
        return sql
    }

    static func buildFilteredCount(
        table: String, schema: String?, type: DatabaseType,
        filters: [TableFilter], logicMode: FilterLogicMode,
        columns: [ColumnInfo] = [],
        session: SQLSessionLexicalFacts? = nil
    ) -> String {
        let dialect = dialectDescriptor(for: type)
        let generator = filterGenerator(dialect: dialect, type: type, session: session)
        let whereClause = generator.generateWhereClause(from: filters, logicMode: logicMode, columns: columns)
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        if whereClause.isEmpty {
            return "SELECT COUNT(*) FROM \(quoted)"
        }
        return "SELECT COUNT(*) FROM \(quoted) \(whereClause)"
    }

    // MARK: - Search

    static func buildSearchSelect(
        table: String, schema: String?, type: DatabaseType,
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter] = [], logicMode: FilterLogicMode = .and,
        columns: [ColumnInfo] = [],
        session: SQLSessionLexicalFacts? = nil,
        sortState: SortState = SortState(),
        limit: Int, offset: Int
    ) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let whereClause = buildSearchWhereClause(
            searchText: searchText, searchColumns: searchColumns,
            filters: filters, logicMode: logicMode, columns: columns, type: type, session: session
        )
        let orderBy = buildOrderByClause(sortState, for: type)
        let pagination = paginationClause(orderBy: orderBy, limit: limit, offset: offset, for: type)
        var sql = "SELECT * FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        sql += " \(pagination)"
        return sql
    }

    static func buildSearchCount(
        table: String, schema: String?, type: DatabaseType,
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter] = [], logicMode: FilterLogicMode = .and,
        columns: [ColumnInfo] = [],
        session: SQLSessionLexicalFacts? = nil
    ) -> String {
        let quoted = qualifiedIdentifier(table: table, schema: schema, for: type)
        let whereClause = buildSearchWhereClause(
            searchText: searchText, searchColumns: searchColumns,
            filters: filters, logicMode: logicMode, columns: columns, type: type, session: session
        )
        var sql = "SELECT COUNT(*) FROM \(quoted)"
        if !whereClause.isEmpty { sql += " \(whereClause)" }
        return sql
    }

    private static func buildSearchWhereClause(
        searchText: String, searchColumns: [ColumnInfo],
        filters: [TableFilter], logicMode: FilterLogicMode,
        columns: [ColumnInfo], type: DatabaseType, session: SQLSessionLexicalFacts?
    ) -> String {
        var whereParts: [String] = []

        let searchClause = buildSearchClause(searchText: searchText, columns: searchColumns, type: type, session: session)
        if !searchClause.isEmpty {
            whereParts.append(searchClause)
        }

        if let filterConditions = filterConditions(
            filters: filters, logicMode: logicMode, columns: columns, type: type, session: session
        ) {
            whereParts.append("(\(filterConditions))")
        }

        guard !whereParts.isEmpty else { return "" }
        return "WHERE " + whereParts.joined(separator: " AND ")
    }

    private static func filterConditions(
        filters: [TableFilter], logicMode: FilterLogicMode, columns: [ColumnInfo], type: DatabaseType,
        session: SQLSessionLexicalFacts?
    ) -> String? {
        let dialect = dialectDescriptor(for: type)
        let generator = filterGenerator(dialect: dialect, type: type, session: session)
        let clause = generator.generateWhereClause(from: filters, logicMode: logicMode, columns: columns)
        guard !clause.isEmpty else { return nil }
        let wherePrefix = "WHERE "
        return clause.hasPrefix(wherePrefix)
            ? String(clause.dropFirst(wherePrefix.count))
            : clause
    }

    private static func buildSearchClause(
        searchText: String, columns: [ColumnInfo], type: DatabaseType, session: SQLSessionLexicalFacts?
    ) -> String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !columns.isEmpty else { return "" }

        let dialect = dialectDescriptor(for: type)
        let generator = filterGenerator(dialect: dialect, type: type, session: session)
        let pattern = generator.likePatternBody(trimmed)
        // D1 refuses a LIKE pattern this long, so the text is found as a plain substring, folded as its LIKE folds.
        let substring = generator.exceedsLikePatternLimit(pattern, wildcards: 2) ? generator.stringLiteral(trimmed) : nil

        let conditions = columns.map { col -> String in
            let quotedCol = quoteIdentifier(col.name, for: type)
            let castExpr = searchCastExpression(quotedCol, for: type)
            if let substring {
                return SQLSubstringMatch.contains(castExpr, literal: substring, fold: dialect.caseFoldFunction)
            }
            let likeOp = (type == .postgresql || type == .redshift) ? "ILIKE" : "LIKE"
            let prefix = type == .mssql ? "N" : ""
            return "\(castExpr) \(likeOp) \(prefix)'%\(pattern)%'\(generator.likeEscapeClause)"
        }

        return "(\(conditions.joined(separator: " OR ")))"
    }

    private static func searchCastExpression(_ quotedColumn: String, for type: DatabaseType) -> String {
        if speaksMySQLDialect(type) {
            return "CAST(\(quotedColumn) AS CHAR)"
        }
        switch type {
        case .postgresql, .redshift:
            return "CAST(\(quotedColumn) AS TEXT)"
        case .mssql:
            return "CAST(\(quotedColumn) AS NVARCHAR(MAX))"
        case .oracle:
            return "CAST(\(quotedColumn) AS VARCHAR2(4000))"
        case .clickhouse:
            return "toString(\(quotedColumn))"
        default:
            return "CAST(\(quotedColumn) AS TEXT)"
        }
    }

    private static func buildOrderByClause(_ sortState: SortState, for type: DatabaseType) -> String {
        guard sortState.isSorting else { return "" }
        let clauses = sortState.columns.map { col in
            "\(quoteIdentifier(col.name, for: type)) \(col.ascending ? "ASC" : "DESC")"
        }
        return "ORDER BY " + clauses.joined(separator: ", ")
    }

    // MongoDB has no SQL dialect; its plugin folds case in the filters it builds, as MongoDBPlugin declares.
    static func caseSensitivityStyle(for type: DatabaseType) -> SQLDialectDescriptor.CaseSensitivityStyle {
        guard type != .mongodb else { return .driverManaged }
        return dialectDescriptor(for: type).caseSensitivityStyle
    }

    // Mirrors each driver plugin's dialect on the Mac: iOS has no plugin bundle to ask. A type that falls to the
    // default arm gets `.unsupported` case sensitivity, plain `LIKE`, and fewer rows than the Mac;
    // `SQLDialectParityTests` catches a driver missing an arm.
    private static func dialectDescriptor(for type: DatabaseType) -> SQLDialectDescriptor {
        if speaksMySQLDialect(type) {
            return SQLDialectDescriptor(
                identifierQuote: "`",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .implicit,
                requiresBackslashEscaping: true,
                caseSensitivityStyle: .collationDefined
            )
        }
        // The ClickHouse and Cloudflare D1 plugins are compiled into this app, so their own dialects are read rather
        // than mirrored.
        if type == .clickhouse, let dialect = ClickHousePlugin.sqlDialect {
            return dialect
        }
        if type == .cloudflareD1, let dialect = CloudflareD1Plugin.sqlDialect {
            return dialect
        }
        switch type {
        case .postgresql:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .ilikeOperator,
                textCastTypeName: "TEXT"
            )
        case .redshift:
            return SQLDialectDescriptor(
                identifierQuote: "\"",
                keywords: [],
                functions: [],
                dataTypes: [],
                likeEscapeStyle: .explicit,
                caseSensitivityStyle: .caseFoldFunction,
                textCastTypeName: "TEXT"
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
                caseSensitivityStyle: .ilikeOperator,
                textCastTypeName: "VARCHAR"
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
