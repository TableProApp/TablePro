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
        let folding = caseFolding(for: filter, columnType: columnType)

        switch filter.filterOperator {
        case .equal:
            switch renderLiteral(filter.value, columnType: columnType) {
            case .null:
                return "\(quotedColumn) IS NULL"
            case .value(let literal):
                return generateComparisonCondition(
                    column: quotedColumn, literal: literal, rawValue: filter.value,
                    negated: false, folding: folding
                )
            }

        case .notEqual:
            switch renderLiteral(filter.value, columnType: columnType) {
            case .null:
                return "\(quotedColumn) IS NOT NULL"
            case .value(let literal):
                return generateComparisonCondition(
                    column: quotedColumn, literal: literal, rawValue: filter.value,
                    negated: true, folding: folding
                )
            }

        case .contains, .notContains, .startsWith, .endsWith:
            return generateLikeFamilyCondition(
                column: quotedColumn, filter: filter, folding: folding
            )

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
                column: quotedColumn, values: filter.value, columnType: columnType,
                negated: false, folding: folding
            )

        case .notInList:
            return generateInCondition(
                column: quotedColumn, values: filter.value, columnType: columnType,
                negated: true, folding: folding
            )

        case .between:
            guard let secondValue = filter.secondValue, !secondValue.isEmpty else { return nil }
            let lower = renderLiteral(filter.value, columnType: columnType).sqlText
            let upper = renderLiteral(secondValue, columnType: columnType).sqlText
            return "\(quotedColumn) BETWEEN \(lower) AND \(upper)"

        case .regex:
            guard dialect.regexSyntax != .unsupported else {
                let pattern = "'%\(escapeSQLQuote(filter.value))%'"
                return "\(folding.foldingLikeOperand(quotedColumn)) \(folding.likeKeyword) "
                    + folding.foldingLikeOperand(pattern)
            }
            return generateRegexCondition(
                column: quotedColumn, pattern: filter.value, ignoresCase: !filter.isCaseSensitive
            )
        }
    }

    // MARK: - Case Sensitivity

    private func caseFolding(for filter: TableFilter, columnType: ColumnType?) -> PluginSQLCaseFolding {
        let matchesCase = filter.isCaseSensitive
            || !filter.filterOperator.supportsCaseSensitivity
            || !allowsCaseFolding(columnType)
        return PluginSQLCaseFolding.resolve(
            style: dialect.caseSensitivityStyle,
            foldFunction: dialect.caseFoldFunction,
            isCaseSensitive: matchesCase
        )
    }

    /// Folding a non-text column is a type error on strict engines, so only fold
    /// columns that are text or whose type the grid has not resolved.
    private func allowsCaseFolding(_ columnType: ColumnType?) -> Bool {
        columnType == nil || ColumnTypeSQLQuoting.isKnownTextLike(columnType)
    }

    private func foldedComparison(_ literal: String, folding: PluginSQLCaseFolding) -> String? {
        guard folding.foldsComparisonOperands else { return literal }
        guard literal.hasPrefix("'") else { return nil }
        return folding.fold(literal)
    }

    // MARK: - IN Conditions

    /// Generate IN/NOT IN with proper NULL handling.
    /// SQL `IN (NULL)` never matches — extract NULLs into a separate IS NULL / IS NOT NULL clause.
    private func generateInCondition(
        column: String,
        values: String,
        columnType: ColumnType?,
        negated: Bool,
        folding: PluginSQLCaseFolding
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
                nonNullValues.append(folding.foldingComparison(literal))
            }
        }

        let foldedColumn = folding.foldingComparison(column)
        let inClause: String? = nonNullValues.isEmpty ? nil : {
            let list = nonNullValues.joined(separator: ", ")
            return negated
                ? "\(foldedColumn) NOT IN (\(list))"
                : "\(foldedColumn) IN (\(list))"
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

    private func generateLikeFamilyCondition(
        column: String,
        filter: TableFilter,
        folding: PluginSQLCaseFolding
    ) -> String {
        let negated = filter.filterOperator == .notContains
        if folding.usesRegexForLike {
            let pattern = PluginSQLRegexPattern.pattern(
                matchingLiteral: filter.value,
                anchoring: regexAnchoring(for: filter.filterOperator),
                ignoresCase: false
            )
            let condition = generateRegexCondition(column: column, pattern: pattern, ignoresCase: true)
            return negated ? "NOT (\(condition))" : condition
        }
        let escaped = escapeLikeWildcards(filter.value)
        let pattern: String
        switch filter.filterOperator {
        case .startsWith:
            pattern = "\(escaped)%"
        case .endsWith:
            pattern = "%\(escaped)"
        default:
            pattern = "%\(escaped)%"
        }
        return generateLikeCondition(column: column, pattern: pattern, negated: negated, folding: folding)
    }

    private func generateLikeCondition(
        column: String,
        pattern: String,
        negated: Bool,
        folding: PluginSQLCaseFolding
    ) -> String {
        let quotedPattern = "'\(escapeSQLQuote(pattern))'"
        let keyword = negated ? folding.notLikeKeyword : folding.likeKeyword
        let operand = folding.foldingLikeOperand(column)
        return "\(operand) \(keyword) \(folding.foldingLikeOperand(quotedPattern))\(likeEscapeClause)"
    }

    private func generateComparisonCondition(
        column: String,
        literal: String,
        rawValue: String,
        negated: Bool,
        folding: PluginSQLCaseFolding
    ) -> String {
        if folding.usesRegexForLike {
            let pattern = PluginSQLRegexPattern.pattern(
                matchingLiteral: rawValue, anchoring: .exact, ignoresCase: false
            )
            let condition = generateRegexCondition(column: column, pattern: pattern, ignoresCase: true)
            return negated ? "NOT (\(condition))" : condition
        }
        let operatorText = negated ? "!=" : "="
        guard let foldedValue = foldedComparison(literal, folding: folding) else {
            return "\(column) \(operatorText) \(literal)"
        }
        let foldedColumn = folding.foldsComparisonOperands ? folding.fold(column) : column
        return "\(foldedColumn) \(operatorText) \(foldedValue)"
    }

    private func regexAnchoring(for filterOperator: FilterOperator) -> PluginSQLRegexPattern.Anchoring {
        switch filterOperator {
        case .startsWith:
            return .prefix
        case .endsWith:
            return .suffix
        default:
            return .unanchored
        }
    }

    // MARK: - REGEX Conditions

    private func generateRegexCondition(column: String, pattern: String, ignoresCase: Bool) -> String {
        let escapedPattern = escapeStringValue(pattern)

        switch dialect.regexSyntax {
        case .regexp:
            guard ignoresCase else { return "\(column) REGEXP '\(escapedPattern)'" }
            return "REGEXP_LIKE(\(column), '\(escapedPattern)', 'i')"
        case .tilde:
            return "\(column) \(ignoresCase ? "~*" : "~") '\(escapedPattern)'"
        case .regexpMatches:
            guard ignoresCase else { return "regexp_matches(\(column), '\(escapedPattern)')" }
            return "regexp_matches(\(column), '\(escapedPattern)', 'i')"
        case .regexpLike:
            guard ignoresCase else { return "REGEXP_LIKE(\(column), '\(escapedPattern)')" }
            return "REGEXP_LIKE(\(column), '\(escapedPattern)', 'i')"
        case .match:
            guard ignoresCase else { return "match(\(column), '\(escapedPattern)')" }
            return "match(\(column), '(?i)\(escapedPattern)')"
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
        @unknown default:
            return nil
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
            let queryFilters = filters
                .filter { $0.isEnabled && !$0.columnName.isEmpty }
                .map(\.asPluginQueryFilter)
            if let result = pluginDriver.buildFilteredQuery(
                table: tableName, schema: schemaName, queryFilters: queryFilters,
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
