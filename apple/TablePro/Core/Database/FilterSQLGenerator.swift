//
//  FilterSQLGenerator.swift
//  TablePro
//
//  Generates SQL WHERE clauses from filter definitions
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

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
    private let stringLiteralPrefix: String
    /// The engine's type family, for the comparisons a dialect descriptor cannot describe.
    private let family: SQLTypeFamily?

    init(
        dialect: SQLDialectDescriptor,
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        quoteIdentifier: ((String) -> String)? = nil,
        stringLiteralPrefix: String = "",
        databaseType: DatabaseType? = nil
    ) {
        self.dialect = dialect
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
        self.columnTypesByName = ColumnTypeSQLQuoting.lookupByName(columns: columns, columnTypes: columnTypes)
        self.stringLiteralPrefix = stringLiteralPrefix
        self.family = databaseType.map(SQLTypeFamily.of)
    }

    /// The one place a string literal is spelled, so the engine's prefix cannot be forgotten on
    /// one arm and applied on another.
    private func quotedLiteral(_ escapedBody: String) -> String {
        "\(stringLiteralPrefix)'\(escapedBody)'"
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
        case .equal, .notEqual:
            let negated = filter.filterOperator == .notEqual
            if let match = eitherStorageComparison(quotedColumn, filter.value, columnType: columnType, negated: negated) {
                return match
            }
            switch renderLiteral(filter.value, columnType: columnType) {
            case .null:
                return "\(quotedColumn) \(negated ? "IS NOT NULL" : "IS NULL")"
            case .value(let literal):
                return generateComparisonCondition(
                    column: quotedColumn, columnType: columnType, literal: literal,
                    rawValue: filter.value, negated: negated, folding: folding
                )
            }

        case .contains, .notContains, .startsWith, .endsWith:
            return generateLikeFamilyCondition(
                column: patternOperand(quotedColumn, columnType: columnType), filter: filter, folding: folding
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
            return "(\(quotedColumn) IS NULL OR \(patternOperand(quotedColumn, columnType: columnType)) = '')"

        case .isNotEmpty:
            guard ColumnTypeSQLQuoting.supportsEmptyStringComparison(columnType) else {
                return "\(quotedColumn) IS NOT NULL"
            }
            return "(\(quotedColumn) IS NOT NULL AND \(patternOperand(quotedColumn, columnType: columnType)) != '')"

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
            let operand = patternOperand(quotedColumn, columnType: columnType)
            guard dialect.regexSyntax != .unsupported else {
                let pattern = quotedLiteral("%\(escapeStringValue(filter.value))%")
                return "\(folding.foldingLikeOperand(operand)) \(folding.likeKeyword) "
                    + folding.foldingLikeOperand(pattern)
            }
            return generateRegexCondition(
                column: operand, pattern: filter.value, ignoresCase: !filter.isCaseSensitive
            )
        }
    }

    /// SQLite keeps integer 5 and text '5' apart in a column with no affinity, and the grid reads both as `5`,
    /// so SQLite's own text for a number matches either one.
    private func eitherStorageComparison(_ column: String, _ value: String, columnType: ColumnType?, negated: Bool) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard comparesEitherStorageClass(columnType), SQLiteNumberText.isStoredSpelling(trimmed) else { return nil }
        return eitherStorageMatch(column, literals: [trimmed, quotedLiteral(trimmed)], texts: [quotedLiteral(trimmed)], negated: negated)
    }

    /// IN keeps the index; CAST holds the match to the text SQLite reads the value back as, which the grid showed,
    /// so a REAL that another spelling of the same number parses to is not matched as well.
    private func eitherStorageMatch(_ column: String, literals: [String], texts: [String], negated: Bool) -> String {
        let read = texts.count == 1 ? "= \(texts[0])" : "IN (\(texts.joined(separator: ", ")))"
        let match = "\(column) IN (\(literals.joined(separator: ", "))) AND CAST(\(column) AS TEXT) \(read)"
        return negated ? "NOT (\(match))" : "(\(match))"
    }

    private func comparesEitherStorageClass(_ columnType: ColumnType?) -> Bool {
        guard family == .sqlite else { return false }
        switch columnType {
        case nil, .blob?:
            return true
        case .text(let rawType)?:
            let declared = (rawType ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return declared.isEmpty || declared == "ANY"
        default:
            return false
        }
    }

    /// The operand `LIKE`, a regex and a case fold see. An engine that names a
    /// `textCastTypeName` refuses those on anything but character data, so every other column
    /// is cast first, including one whose type the grid has not resolved yet, because a cast
    /// to text is valid on every column and a bare operand is not. A plain `=` keeps the
    /// column's own type and its index.
    private func patternOperand(_ column: String, columnType: ColumnType?) -> String {
        guard let castType = dialect.textCastTypeName,
              !ColumnTypeSQLQuoting.isCharacterType(columnType) else { return column }
        return "CAST(\(column) AS \(castType))"
    }

    // MARK: - Case Sensitivity

    private func caseFolding(for filter: TableFilter, columnType: ColumnType?) -> PluginSQLCaseFolding {
        let matchesCase = filter.isCaseSensitive
            || !filter.filterOperator.supportsCaseSensitivity
            || !allowsCaseFolding(columnType)
            || Self.comparisonOperators.contains(filter.filterOperator) && hasNoCase(columnType)
        return PluginSQLCaseFolding.resolve(
            style: dialect.caseSensitivityStyle,
            foldFunction: dialect.caseFoldFunction,
            isCaseSensitive: matchesCase
        )
    }

    /// Folding a non-text column is a type error on strict engines, so only fold
    /// columns that are text or whose type the grid has not resolved, unless the
    /// dialect casts the operand to text first, which makes every column foldable.
    private func allowsCaseFolding(_ columnType: ColumnType?) -> Bool {
        columnType == nil
            || ColumnTypeSQLQuoting.isKnownTextLike(columnType)
            || dialect.textCastTypeName != nil
    }

    /// A number or a boolean has no case, and compared folded as text `5.50` would no longer equal `5.5`.
    /// A pattern still folds: `contains TRUE` finds PostgreSQL's `true`.
    private func hasNoCase(_ columnType: ColumnType?) -> Bool {
        switch columnType {
        case .integer?, .decimal?, .boolean?:
            return true
        default:
            return false
        }
    }

    private static let comparisonOperators: Set<FilterOperator> = [.equal, .notEqual, .inList, .notInList]

    private func foldedComparison(_ literal: String, folding: PluginSQLCaseFolding) -> String? {
        guard folding.foldsComparisonOperands else { return literal }
        guard literal.unicodeScalars.first == "'" else { return nil }
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
        let parsed = FilterOperand.listItems(values)
        guard !parsed.isEmpty else { return nil }

        var literals: [String] = []
        var texts: [String] = []
        var hasNull = false
        let eitherStorage = comparesEitherStorageClass(columnType)
        for item in parsed {
            if eitherStorage, SQLiteNumberText.isStoredSpelling(item) {
                literals.append(contentsOf: [item, quotedLiteral(item)])
                texts.append(quotedLiteral(item))
                continue
            }
            switch renderLiteral(item, columnType: columnType) {
            case .null:
                hasNull = true
            case .value(let literal):
                literals.append(literal)
                texts.append(literal)
            }
        }

        let foldsList = folding.foldsComparisonOperands && literals.allSatisfy { $0.unicodeScalars.first == "'" }
        let nonNullValues = foldsList ? literals.map(folding.fold) : literals
        let foldedColumn = foldsList ? folding.fold(patternOperand(column, columnType: columnType)) : column
        let inClause: String? = nonNullValues.isEmpty ? nil : {
            if eitherStorage, literals.count > texts.count {
                return eitherStorageMatch(column, literals: literals, texts: texts, negated: negated)
            }
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

    // An implicit-style engine escapes LIKE with a backslash by default and takes no clause.
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
        let quotedPattern = quotedLiteral(escapeStringValue(pattern))
        let keyword = negated ? folding.notLikeKeyword : folding.likeKeyword
        let operand = folding.foldingLikeOperand(column)
        return "\(operand) \(keyword) \(folding.foldingLikeOperand(quotedPattern))\(likeEscapeClause)"
    }

    private func generateComparisonCondition(
        column: String,
        columnType: ColumnType?,
        literal: String,
        rawValue: String,
        negated: Bool,
        folding: PluginSQLCaseFolding
    ) -> String {
        if folding.usesRegexForLike {
            let pattern = PluginSQLRegexPattern.pattern(
                matchingLiteral: rawValue, anchoring: .exact, ignoresCase: false
            )
            let condition = generateRegexCondition(
                column: patternOperand(column, columnType: columnType), pattern: pattern, ignoresCase: true
            )
            return negated ? "NOT (\(condition))" : condition
        }
        let operatorText = negated ? "!=" : "="
        guard let foldedValue = foldedComparison(literal, folding: folding) else {
            return "\(column) \(operatorText) \(literal)"
        }
        let foldedColumn = folding.foldsComparisonOperands
            ? folding.fold(patternOperand(column, columnType: columnType))
            : column
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
            // Trino's REGEXP_LIKE takes two arguments and reads case from a flag inside the pattern.
            guard dialect.caseSensitivityStyle != .regexFlag else {
                return "REGEXP_LIKE(\(column), '(?i)\(escapedPattern)')"
            }
            return "REGEXP_LIKE(\(column), '\(escapedPattern)', 'i')"
        case .match:
            guard ignoresCase else { return "match(\(column), '\(escapedPattern)')" }
            return "match(\(column), '(?i)\(escapedPattern)')"
        case .unsupported:
            return "\(column) LIKE \(quotedLiteral("%\(escapedPattern)%"))"
        }
    }

    // MARK: - Value Escaping

    private func renderLiteral(_ value: String, columnType: ColumnType?) -> RenderedLiteral {
        guard !FilterOperand.readsAsNullLiteral(value, columnType: columnType) else { return .null }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if let booleanLiteral = booleanLiteral(for: trimmed, columnType: columnType) {
            return .value(booleanLiteral)
        }

        if ColumnTypeSQLQuoting.isNumericLiteral(trimmed, for: columnType) && !quotesNumbers(of: columnType) {
            return .value(trimmed)
        }

        if readsBitAsNumber(columnType) && RowValueCopyFormatter.isIntegerLiteral(trimmed) {
            return .value(trimmed)
        }

        if let temporal = oracleTemporalLiteral(trimmed, columnType: columnType) {
            return .value(temporal)
        }

        return .value(quotedLiteral(escapeStringValue(trimmed)))
    }

    // Oracle reads a quoted date through NLS_DATE_FORMAT, `DD-MON-RR` by default, and rejects
    // `'2024-01-05'` with ORA-01861; its ANSI literals take exactly these shapes, the time with seconds.
    private func oracleTemporalLiteral(_ value: String, columnType: ColumnType?) -> String? {
        guard family == .oracle, let columnType, columnType.isDateType, !columnType.isTimeOnly else { return nil }
        let characters = Array(value)
        let isDigit: (Int) -> Bool = { characters[$0].isASCII && characters[$0].isNumber }
        guard characters.count >= 10, [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy(isDigit),
              characters[4] == "-", characters[7] == "-" else { return nil }
        if characters.count == 10 { return "DATE '\(value)'" }
        guard characters.count >= 19, characters[10] == " " || characters[10] == "T",
              [11, 12, 14, 15, 17, 18].allSatisfy(isDigit), characters[13] == ":", characters[16] == ":"
        else { return nil }
        let fraction = characters.dropFirst(19)
        if !fraction.isEmpty {
            guard fraction.first == ".", (2...10).contains(fraction.count),
                  (20 ..< characters.count).allSatisfy(isDigit) else { return nil }
        }
        return "TIMESTAMP '\(String(characters[0..<10])) \(String(characters[11...]))'"
    }

    /// PostgreSQL gives a quoted literal the column's own type, and a `real` never equals the numeric `0.1`.
    private func quotesNumbers(of columnType: ColumnType?) -> Bool {
        guard family == .postgres, case .decimal? = columnType else { return false }
        return true
    }

    /// MySQL reads a `BIT` back as the number it holds and finds no row for `bit = '5'`.
    private func readsBitAsNumber(_ columnType: ColumnType?) -> Bool {
        guard let family, family.readsBitsAsDecimal, case .boolean(let rawType)? = columnType, let rawType,
              case .bitString = SQLTypeParser.parse(rawType, family: family).kind
        else { return false }
        return true
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

    // Snowflake takes `ESCAPE '!'` yet reads `\'` as a quote; BigQuery and Spanner read `\` without declaring it.
    private var literalsReadBackslash: Bool {
        dialect.requiresBackslashEscaping || dialect.likeEscapeStyle == .implicit
    }

    // `.literal` compares code units: the default compares grapheme clusters and skips a quote a combining mark follows.
    private func escapeStringValue(_ value: String) -> String {
        let body = literalsReadBackslash
            ? value.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            : value
        return body.replacingOccurrences(of: "'", with: "''", options: .literal)
    }

    // Only the LIKE layer: escapeStringValue then spells the pattern as a literal.
    private func escapeLikeWildcards(_ value: String) -> String {
        let escape = dialect.likeEscapeStyle == .implicit ? "\\" : "!"
        // `[` opens a character class in a SQL Server LIKE pattern.
        let metacharacters = [escape, "%", "_"] + (family == .mssql ? ["["] : [])
        return metacharacters.reduce(value) { pattern, metacharacter in
            pattern.replacingOccurrences(of: metacharacter, with: escape + metacharacter, options: .literal)
        }
    }
}

// MARK: - Preview/Display Helpers

extension FilterSQLGenerator {
    /// Generate a preview-friendly query string (for display, not execution)
    func generatePreviewSQL(
        tableName: String,
        schemaName: String? = nil,
        implicitSchemaName: String? = nil,
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

        let quotedTable = SchemaQualifiedName.render(
            name: tableName, schema: schemaName, implicitSchemaName: implicitSchemaName, quote: quoteIdentifierFn
        )
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
