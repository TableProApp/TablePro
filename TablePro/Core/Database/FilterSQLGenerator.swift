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
    private let dialect: SQLDialectDescriptor
    private let quoteIdentifierFn: (String) -> String

    init(
        dialect: SQLDialectDescriptor,
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        self.dialect = dialect
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
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

    /// Generate a single filter condition
    func generateCondition(from filter: TableFilter) -> String? {
        guard filter.isValid else { return nil }

        // Raw SQL mode - return as-is
        if filter.isRawSQL, let rawSQL = filter.rawSQL {
            return "(\(rawSQL))"
        }

        let quotedColumn = quoteIdentifierFn(filter.columnName)

        switch filter.filterOperator {
        case .equal:
            let escaped = escapeValue(filter.value)
            if escaped == "NULL" { return "\(quotedColumn) IS NULL" }
            return "\(quotedColumn) = \(escaped)"

        case .notEqual:
            let escaped = escapeValue(filter.value)
            if escaped == "NULL" { return "\(quotedColumn) IS NOT NULL" }
            return "\(quotedColumn) != \(escaped)"

        case .contains:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .notContains:
            return generateNotLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))%")

        case .startsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "\(escapeLikeWildcards(filter.value))%")

        case .endsWith:
            return generateLikeCondition(column: quotedColumn, pattern: "%\(escapeLikeWildcards(filter.value))")

        case .greaterThan:
            return "\(quotedColumn) > \(escapeValue(filter.value))"

        case .greaterOrEqual:
            return "\(quotedColumn) >= \(escapeValue(filter.value))"

        case .lessThan:
            return "\(quotedColumn) < \(escapeValue(filter.value))"

        case .lessOrEqual:
            return "\(quotedColumn) <= \(escapeValue(filter.value))"

        case .isNull:
            return "\(quotedColumn) IS NULL"

        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"

        case .isEmpty:
            return "(\(quotedColumn) IS NULL OR \(quotedColumn) = '')"

        case .isNotEmpty:
            return "(\(quotedColumn) IS NOT NULL AND \(quotedColumn) != '')"

        case .inList:
            return generateInCondition(column: quotedColumn, values: filter.value, negated: false)

        case .notInList:
            return generateInCondition(column: quotedColumn, values: filter.value, negated: true)

        case .between:
            guard let secondValue = filter.secondValue, !secondValue.isEmpty else { return nil }
            return "\(quotedColumn) BETWEEN \(escapeValue(filter.value)) AND \(escapeValue(secondValue))"

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
    private func generateInCondition(column: String, values: String, negated: Bool) -> String? {
        let parsed = parseListValues(values)
        guard !parsed.isEmpty else { return nil }

        var nonNullValues: [String] = []
        var hasNull = false
        for item in parsed {
            if item.caseInsensitiveCompare("NULL") == .orderedSame {
                hasNull = true
            } else {
                nonNullValues.append(escapeValue(item))
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
        return " ESCAPE '\\'"
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

    /// Escape a value for SQL, auto-detecting type
    private func escapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Check for NULL literal (case-insensitive without allocating uppercased copy)
        if trimmed.caseInsensitiveCompare("NULL") == .orderedSame {
            return "NULL"
        }

        // Check for boolean literals
        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame {
            return dialect.booleanLiteralStyle == .truefalse ? "TRUE" : "1"
        }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame {
            return dialect.booleanLiteralStyle == .truefalse ? "FALSE" : "0"
        }

        // Try to detect numeric values
        if Int(trimmed) != nil || Double(trimmed) != nil {
            return trimmed
        }

        // String value - escape and quote
        return "'\(escapeStringValue(trimmed))'"
    }

    /// Escape only single quotes for SQL string literal context.
    /// Used for LIKE patterns where backslashes are already escaped
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
        guard value.contains("\\") || value.contains("%") || value.contains("_") else { return value }

        if dialect.likeEscapeStyle == .implicit {
            // MySQL uses \ as both string escape and default LIKE escape.
            // Need double backslash in SQL string so string layer yields single \
            // which LIKE then uses as escape char.
            return value
                .replacingOccurrences(of: "\\", with: "\\\\\\\\")
                .replacingOccurrences(of: "%", with: "\\\\%")
                .replacingOccurrences(of: "_", with: "\\\\_")
        }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - List Parsing

    /// Parse comma-separated list values
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
                table: tableName, filters: filterTuples,
                logicMode: logicMode == .and ? "and" : "or",
                sortColumns: [], columns: [],
                limit: limit, offset: 0
            ) {
                return result
            }
        }

        let quotedTable = quoteIdentifierFn(tableName)
        var sql = "SELECT * FROM \(quotedTable)"

        let whereClause = generateWhereClause(from: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            sql += "\n\(whereClause)"
        }

        if dialect.paginationStyle == .offsetFetch {
            let orderBy = dialect.offsetFetchOrderBy
            sql += "\n\(orderBy) OFFSET 0 ROWS FETCH NEXT \(limit) ROWS ONLY"
        } else {
            sql += "\nLIMIT \(limit)"
        }
        return sql
    }
}
