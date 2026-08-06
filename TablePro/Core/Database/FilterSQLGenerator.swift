//
//  FilterSQLGenerator.swift
//  TablePro
//
//  Generates SQL WHERE clauses from filter definitions
//

import Foundation
import TableProPluginKit

/// Generates SQL WHERE clauses from filter definitions
struct FilterSQLGenerator {
    private enum RenderedLiteral {
        case null
        case value(String)

        var sqlText: String {
            switch self {
            case .null:
                return "NULL"
            case .value(let text):
                return text
            }
        }
    }

    private let dialect: SQLDialectDescriptor
    private let quoteIdentifierFn: (String) -> String
    private let columnTypesByName: [String: ColumnType]

    init(
        dialect: SQLDialectDescriptor,
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        self.dialect = dialect
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
        self.columnTypesByName = ColumnTypeSQLQuoting.lookupByName(columns: columns, columnTypes: columnTypes)
    }

    // MARK: - Public API

    /// Generate a complete WHERE clause from filters
    func generateWhereClause(from filters: [TableFilter], logicMode: FilterLogicMode = .and) -> String {
        let conditions = filters.compactMap { generateCondition(from: $0) }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == .and ? " AND " : " OR "
        return "WHERE " + conditions.joined(separator: separator)
    }

    /// Generate just the conditions (without WHERE keyword)
    func generateConditions(from filters: [TableFilter], logicMode: FilterLogicMode = .and) -> String {
        let conditions = filters.compactMap { generateCondition(from: $0) }
        let separator = logicMode == .and ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    func generateCondition(from filter: TableFilter) -> String? {
        guard filter.isValid else { return nil }

        if filter.isRawSQL, let rawSQL = filter.rawSQL {
            guard SQLBoundaryValidator.isRawFilterConditionSafe(rawSQL) else { return nil }
            return "(\(rawSQL))"
        }

        let quotedColumn = quoteIdentifierFn(filter.columnName)
        let columnType = columnTypesByName[filter.columnName]

        switch filter.filterOperator {
        case .equal:
            switch renderLiteral(filter.value, columnType: columnType) {
            case .null:
                return "\(quotedColumn) IS NULL"
            case .value(let literal):
                return "\(quotedColumn) = \(literal)"
            }

        case .notEqual:
            switch renderLiteral(filter.value, columnType: columnType) {
            case .null:
                return "\(quotedColumn) IS NOT NULL"
            case .value(let literal):
                return "\(quotedColumn) != \(literal)"
            }

        case .contains:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .notContains:
            return generateNotLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .startsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "\(escapeLikeWildcards(filter.value))%")

        case .endsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))")

        case .greaterThan:
            return "\(quotedColumn) > \(renderLiteral(filter.value, columnType: columnType).sqlText)"

        case .greaterOrEqual:
            return "\(quotedColumn) >= \(renderLiteral(filter.value, columnType: columnType).sqlText)"

        case .lessThan:
            return "\(quotedColumn) < \(renderLiteral(filter.value, columnType: columnType).sqlText)"

        case .lessOrEqual:
            return "\(quotedColumn) <= \(renderLiteral(filter.value, columnType: columnType).sqlText)"

        case .isNull:
            return "\(quotedColumn) IS NULL"

        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"

        case .isEmpty:
            guard ColumnTypeSQLQuoting.supportsEmptyStringComparison(columnType) else {
                return "\(quotedColumn) IS NULL"
            }
            return "(\(quotedColumn) IS NULL OR \(quotedColumn) = '')"

        case .isNotEmpty:
            guard ColumnTypeSQLQuoting.supportsEmptyStringComparison(columnType) else {
                return "\(quotedColumn) IS NOT NULL"
            }
            return "(\(quotedColumn) IS NOT NULL AND \(quotedColumn) != '')"

        case .inList:
            return generateInCondition(
                column: quotedColumn, values: filter.value, columnType: columnType, negated: false
            )

        case .notInList:
            return generateInCondition(
                column: quotedColumn, values: filter.value, columnType: columnType, negated: true
            )

        case .between:
            guard let secondValue = filter.secondValue, !secondValue.isEmpty else { return nil }
            let lower = renderLiteral(filter.value, columnType: columnType).sqlText
            let upper = renderLiteral(secondValue, columnType: columnType).sqlText
            return "\(quotedColumn) BETWEEN \(lower) AND \(upper)"

        case .regex:
            let syntax = dialect.regexSyntax
            if syntax == .unsupported {
                let escaped = escapeSQLQuote(filter.value)
                return "\(quotedColumn) LIKE '%\(escaped)%'"
            }
            if syntax == .match {
                let escapedPattern = escapeStringValue(filter.value)
                return "match(\(quotedColumn), '\(escapedPattern)')"
            }
            return generateRegexCondition(column: quotedColumn, pattern: filter.value)
        }
    }

    // MARK: - IN Conditions

    /// Generate IN/NOT IN with proper NULL handling.
    /// SQL `IN (NULL)` never matches — extract NULLs into a separate IS NULL / IS NOT NULL clause.
    private func generateInCondition(
        column: String,
        values: String,
        columnType: ColumnType?,
        negated: Bool
    ) -> String? {
        let parsed = parseListValues(values)
        guard !parsed.isEmpty else { return nil }

        var nonNullValues: [String] = []
        var hasNull = false
        for item in parsed {
            switch renderLiteral(item, columnType: columnType) {
            case .null:
                hasNull = true
            case .value(let literal):
                nonNullValues.append(literal)
            }
        }

        let inClause: String? = nonNullValues.isEmpty ? nil : {
            let list = nonNullValues.joined(separator: ", ")
            return negated
                ? "\(column) NOT IN (\(list))"
                : "\(column) IN (\(list))"
        }()

        let nullClause: String? = hasNull ? {
            negated ? "\(column) IS NOT NULL" : "\(column) IS NULL"
        }() : nil

        switch (inClause, nullClause) {
        case let (inC?, nullC?):
            let joiner = negated ? " AND " : " OR "
            return "(\(inC)\(joiner)\(nullC))"
        case let (inC?, nil):
            return inC
        case let (nil, nullC?):
            return nullC
        case (nil, nil):
            return nil
        }
    }

    // MARK: - LIKE Conditions

    /// Database-specific ESCAPE clause for LIKE patterns.
    /// Implicit style (MySQL/MariaDB): backslash is the default LIKE escape, no clause needed.
    /// Explicit style: requires an ESCAPE declaration.
    private var likeEscapeClause: String {
        if dialect.likeEscapeStyle == .implicit { return "" }
        return " ESCAPE '!'"
    }

    private func generateLikeCondition(column: String, pattern: String) -> String {
        let quotedPattern = escapeSQLQuote(pattern)
        return "\(column) LIKE '\(quotedPattern)'\(likeEscapeClause)"
    }

    private func generateNotLikeCondition(column: String, pattern: String) -> String {
        let quotedPattern = escapeSQLQuote(pattern)
        return "\(column) NOT LIKE '\(quotedPattern)'\(likeEscapeClause)"
    }

    // MARK: - REGEX Conditions

    private func generateRegexCondition(column: String, pattern: String) -> String {
        let escapedPattern = escapeStringValue(pattern)

        switch dialect.regexSyntax {
        case .regexp:
            return "\(column) REGEXP '\(escapedPattern)'"
        case .tilde:
            return "\(column) ~ '\(escapedPattern)'"
        case .regexpMatches:
            return "regexp_matches(\(column), '\(escapedPattern)')"
        case .regexpLike:
            return "REGEXP_LIKE(\(column), '\(escapedPattern)')"
        case .match:
            return "match(\(column), '\(escapedPattern)')"
        case .unsupported:
            return "\(column) LIKE '%\(escapedPattern)%'"
        }
    }

    // MARK: - Value Escaping

    private func renderLiteral(_ value: String, columnType: ColumnType?) -> RenderedLiteral {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if !ColumnTypeSQLQuoting.isKnownTextLike(columnType),
           trimmed.caseInsensitiveCompare("NULL") == .orderedSame {
            return .null
        }

        if let booleanLiteral = booleanLiteral(for: trimmed, columnType: columnType) {
            return .value(booleanLiteral)
        }

        if ColumnTypeSQLQuoting.isNumericLiteral(trimmed, for: columnType) {
            return .value(trimmed)
        }

        return .value("'\(escapeStringValue(trimmed))'")
    }

    private func booleanLiteral(for value: String, columnType: ColumnType?) -> String? {
        guard let columnType else { return legacyBooleanLiteral(for: value) }
        guard columnType.isBooleanType else { return nil }
        guard let synonym = ColumnTypeSQLQuoting.booleanSynonym(for: value) else { return nil }
        switch synonym {
        case .isTrue:
            return booleanText(isTrue: true)
        case .isFalse:
            return booleanText(isTrue: false)
        }
    }

    private func legacyBooleanLiteral(for value: String) -> String? {
        if value.caseInsensitiveCompare("TRUE") == .orderedSame { return booleanText(isTrue: true) }
        if value.caseInsensitiveCompare("FALSE") == .orderedSame { return booleanText(isTrue: false) }
        return nil
    }

    private func booleanText(isTrue: Bool) -> String {
        if dialect.booleanLiteralStyle == .truefalse {
            return isTrue ? "TRUE" : "FALSE"
        }
        return isTrue ? "1" : "0"
    }

    /// Escape only single quotes for SQL string literal context.
    /// Used for LIKE patterns where wildcards are already escaped
    /// by escapeLikeWildcards for the ESCAPE clause.
    private func escapeSQLQuote(_ value: String) -> String {
        guard value.contains("'") else { return value }
        return value.replacingOccurrences(of: "'", with: "''")
    }

    /// Escape special characters in string values
    private func escapeStringValue(_ value: String) -> String {
        // Fast path: most values have no special chars
        if dialect.likeEscapeStyle == .implicit {
            // MySQL/MariaDB/ClickHouse: backslash is significant in string literals
            guard value.contains("\\") || value.contains("'") else { return value }
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''")
        } else {
            // ANSI SQL: only single-quote needs escaping
            guard value.contains("'") else { return value }
            return value.replacingOccurrences(of: "'", with: "''")
        }
    }

    private func escapeLikeWildcards(_ value: String) -> String {
        if dialect.likeEscapeStyle == .implicit {
            guard value.contains("\\") || value.contains("%") || value.contains("_") else { return value }
            // MySQL uses \ as both string escape and default LIKE escape.
            // Need double backslash in SQL string so string layer yields single \
            // which LIKE then uses as escape char.
            return value
                .replacingOccurrences(of: "\\", with: "\\\\\\\\")
                .replacingOccurrences(of: "%", with: "\\\\%")
                .replacingOccurrences(of: "_", with: "\\\\_")
        }
        guard value.contains("!") || value.contains("%") || value.contains("_") else { return value }
        return value
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
    }

    // MARK: - List Parsing

    private func parseListValues(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: true)
            .compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
    }
}

// MARK: - Preview/Display Helpers

extension FilterSQLGenerator {
    /// Generate a preview-friendly query string (for display, not execution)
    func generatePreviewSQL(
        tableName: String,
        schemaName: String? = nil,
        filters: [TableFilter],
        logicMode: FilterLogicMode = .and,
        limit: Int = 1_000,
        pluginDriver: (any PluginDatabaseDriver)? = nil
    ) -> String {
        // Use plugin dispatch for NoSQL drivers (MongoDB, Redis, etc.)
        if let pluginDriver {
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
                table: tableName, schema: schemaName, filters: filterTuples,
                logicMode: logicMode == .and ? "and" : "or",
                sortColumns: [], columns: [],
                limit: limit, offset: 0,
                columnKinds: columnTypesByName.mapValues(\.pluginColumnKind)
            ) {
                return result
            }
        }

        let quotedTable: String
        if let schemaName, !schemaName.isEmpty {
            quotedTable = "\(quoteIdentifierFn(schemaName)).\(quoteIdentifierFn(tableName))"
        } else {
            quotedTable = quoteIdentifierFn(tableName)
        }
        var sql = "SELECT * FROM \(quotedTable)"

        let whereClause = generateWhereClause(from: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            sql += "\n\(whereClause)"
        }

        if dialect.paginationStyle == .offsetFetch {
            let orderBy = dialect.offsetFetchOrderBy
            let orderByPrefix = orderBy.isEmpty ? "" : "\(orderBy) "
            sql += "\n\(orderByPrefix)OFFSET 0 ROWS FETCH NEXT \(limit) ROWS ONLY"
        } else {
            sql += "\nLIMIT \(limit)"
        }
        return sql
    }
}
