import Foundation
import TableProCoreTypes
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

public struct FilterSQLGenerator: Sendable {
    private let dialect: SQLDialectDescriptor
    private let databaseType: DatabaseType?
    private let identifierQuoter: (@Sendable (String) -> String)?
    private let literalEscapes: SQLStringEscapes

    // A dialect names its quote character only; ClickHouse also reads backslash escapes inside backticks, so a caller
    // that quotes per engine passes its own quoter. `session` is what the connection reported, such as MySQL's
    // NO_BACKSLASH_ESCAPES; without it a literal is written so that every reading of the engine ends it in place.
    public init(
        dialect: SQLDialectDescriptor,
        databaseType: DatabaseType? = nil,
        quoteIdentifier: (@Sendable (String) -> String)? = nil,
        session: SQLSessionLexicalFacts? = nil
    ) {
        self.dialect = dialect
        self.databaseType = databaseType
        self.identifierQuoter = quoteIdentifier
        let declared: SQLLexicalGrammar = dialect.requiresBackslashEscaping ? .backslashEscapesInSingleQuotes : []
        self.literalEscapes = SQLLexicalReadings.stringEscapes(
            databaseTypeId: databaseType?.rawValue ?? "", declared: declared, session: session
        )
    }

    public func generateWhereClause(
        from filters: [TableFilter],
        logicMode: FilterLogicMode,
        columns: [ColumnInfo] = []
    ) -> String {
        let activeFilters = filters.filter { $0.isEnabled && $0.isValid }
        guard !activeFilters.isEmpty else { return "" }

        let conditions = activeFilters.compactMap { generateCondition(for: $0, columns: columns) }
        guard !conditions.isEmpty else { return "" }

        let joined = conditions.joined(separator: " \(logicMode.rawValue) ")
        return "WHERE \(joined)"
    }

    private func generateCondition(for filter: TableFilter, columns: [ColumnInfo]) -> String? {
        if filter.columnName == TableFilter.rawSQLColumn {
            guard let rawSQL = filter.rawSQL, !rawSQL.isEmpty else { return nil }
            return rawSQL
        }

        let quotedColumn = quoteIdentifier(filter.columnName)
        let column = FilterColumnKind.column(named: filter.columnName, in: columns)
        let kind = FilterColumnKind.kind(of: column, databaseType: databaseType)
        let eitherStorageClass = FilterColumnKind.comparesEitherStorageClass(column, databaseType: databaseType)
        let escapedValue = escapeValue(filter.value, kind: kind)
        let folding = caseFolding(for: filter, column: column)
        let operand = textOperand(quotedColumn, for: column)

        switch filter.filterOperator {
        case .equal where eitherStorageClass:
            return eitherStorageComparison(quotedColumn, filter.value, negated: false)
        case .notEqual where eitherStorageClass:
            return eitherStorageComparison(quotedColumn, filter.value, negated: true)
        case .equal:
            return comparisonCondition(quotedColumn, operand, "=", escapedValue, folding: folding)
        case .notEqual:
            return comparisonCondition(quotedColumn, operand, "!=", escapedValue, folding: folding)
        case .greaterThan:
            return "\(quotedColumn) > \(escapedValue)"
        case .greaterThanOrEqual:
            return "\(quotedColumn) >= \(escapedValue)"
        case .lessThan:
            return "\(quotedColumn) < \(escapedValue)"
        case .lessThanOrEqual:
            return "\(quotedColumn) <= \(escapedValue)"
        case .like:
            return likeCondition(operand, escapedValue, negated: false, folding: folding)
        case .notLike:
            return likeCondition(operand, escapedValue, negated: true, folding: folding)
        case .isNull:
            return "\(quotedColumn) IS NULL"
        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"
        case .in where eitherStorageClass:
            return eitherStorageList(quotedColumn, listItems(filter.value), negated: false)
        case .notIn where eitherStorageClass:
            return eitherStorageList(quotedColumn, listItems(filter.value), negated: true)
        case .in:
            return listCondition(quotedColumn, operand, filter.value, kind: kind, negated: false, folding: folding)
        case .notIn:
            return listCondition(quotedColumn, operand, filter.value, kind: kind, negated: true, folding: folding)
        case .between:
            let escapedSecond = escapeValue(filter.secondValue, kind: kind)
            return "\(quotedColumn) BETWEEN \(escapedValue) AND \(escapedSecond)"
        case .contains:
            let pattern = likePatternBody(filter.value)
            if exceedsLikePatternLimit(pattern, wildcards: 2) {
                return SQLSubstringMatch.contains(operand, literal: stringLiteral(filter.value), fold: dialect.caseFoldFunction)
            }
            return likeCondition(operand, "'%\(pattern)%'", negated: false, folding: folding)
        case .startsWith:
            let pattern = likePatternBody(filter.value)
            if exceedsLikePatternLimit(pattern, wildcards: 1) {
                return SQLSubstringMatch.startsWith(operand, literal: stringLiteral(filter.value), fold: dialect.caseFoldFunction)
            }
            return likeCondition(operand, "'\(pattern)%'", negated: false, folding: folding)
        case .endsWith:
            let pattern = likePatternBody(filter.value)
            if exceedsLikePatternLimit(pattern, wildcards: 1) {
                return SQLSubstringMatch.endsWith(operand, literal: stringLiteral(filter.value), fold: dialect.caseFoldFunction)
            }
            return likeCondition(operand, "'%\(pattern)'", negated: false, folding: folding)
        }
    }

    // An engine that refuses a LIKE pattern this long (D1 past 50 bytes) gets the plain substring test instead, which
    // reads no wildcard, so its literal carries no LIKE escape.
    public func exceedsLikePatternLimit(_ patternBody: String, wildcards: Int) -> Bool {
        SQLSubstringMatch.exceeds(patternBody, wildcards: wildcards, limit: dialect.likePatternByteLimit)
    }

    public func stringLiteral(_ value: String) -> String {
        "'\(literalBody(value))'"
    }

    // A number, a boolean or a bit has no case, and compared folded as text `5.50` would no longer equal `5.5`.
    // A pattern still folds: `contains TRUE` finds PostgreSQL's `true`.
    private func caseFolding(for filter: TableFilter, column: ColumnInfo?) -> PluginSQLCaseFolding {
        let comparesWithoutCase = Self.comparisonOperators.contains(filter.filterOperator)
            && FilterColumnKind.kind(of: column).map { $0 != .text } ?? false
        return PluginSQLCaseFolding.resolve(
            style: dialect.caseSensitivityStyle,
            foldFunction: dialect.caseFoldFunction,
            isCaseSensitive: filter.isCaseSensitive || !filter.filterOperator.supportsCaseSensitivity
                || comparesWithoutCase
        )
    }

    private static let comparisonOperators: Set<FilterOperator> = [.equal, .notEqual, .in, .notIn]

    // A plain comparison keeps the column's own type and its index; only a case fold reads it as text.
    private func comparisonCondition(
        _ column: String, _ operand: String, _ operatorText: String, _ literal: String, folding: PluginSQLCaseFolding
    ) -> String {
        guard folding.foldsComparisonOperands, literal.unicodeScalars.first == "'" else {
            return "\(column) \(operatorText) \(literal)"
        }
        return "\(folding.fold(operand)) \(operatorText) \(folding.fold(literal))"
    }

    private func eitherStorageComparison(_ column: String, _ value: String, negated: Bool) -> String {
        guard SQLiteNumberText.isStoredSpelling(value) else {
            return "\(column) \(negated ? "!=" : "=") \(escapeValue(value, kind: .text))"
        }
        return eitherStorageList(column, [value], negated: negated)
    }

    // IN keeps the index; CAST holds the match to the text SQLite reads the value back as, which the grid showed,
    // so a REAL that another spelling of the same number parses to is not matched as well.
    private func eitherStorageList(_ column: String, _ values: [String], negated: Bool) -> String {
        let quoted = values.map { escapeValue($0, kind: .text) }
        let literals = zip(values, quoted).flatMap { value, text in
            SQLiteNumberText.isStoredSpelling(value) ? [value, text] : [text]
        }
        guard literals.count > quoted.count else {
            return "\(column) \(negated ? "NOT IN" : "IN") (\(quoted.joined(separator: ", ")))"
        }
        let read = quoted.count == 1 ? "= \(quoted[0])" : "IN (\(quoted.joined(separator: ", ")))"
        let match = "\(column) IN (\(literals.joined(separator: ", "))) AND CAST(\(column) AS TEXT) \(read)"
        return negated ? "NOT (\(match))" : "(\(match))"
    }

    // PostgreSQL and DuckDB have no LIKE or lower() for uuid, numbers or enums, and a text cast is valid on every column.
    private func textOperand(_ quotedColumn: String, for column: ColumnInfo?) -> String {
        guard let castType = dialect.textCastTypeName, !FilterColumnKind.isCharacterType(column) else { return quotedColumn }
        return "CAST(\(quotedColumn) AS \(castType))"
    }

    private func listItems(_ rawValue: String) -> [String] {
        rawValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func likeCondition(
        _ column: String, _ pattern: String, negated: Bool, folding: PluginSQLCaseFolding
    ) -> String {
        let keyword = negated ? folding.notLikeKeyword : folding.likeKeyword
        return "\(folding.foldingLikeOperand(column)) \(keyword) \(folding.foldingLikeOperand(pattern))\(likeEscapeClause)"
    }

    private func listCondition(
        _ column: String,
        _ operand: String,
        _ rawValue: String,
        kind: PluginColumnKind?,
        negated: Bool,
        folding: PluginSQLCaseFolding
    ) -> String {
        let keyword = negated ? "NOT IN" : "IN"
        let items = listItems(rawValue).map { escapeValue($0, kind: kind) }
        let foldable = folding.foldsComparisonOperands && items.allSatisfy { $0.unicodeScalars.first == "'" }
        let rendered = foldable ? items.map { folding.fold($0) } : items
        let subject = foldable ? folding.fold(operand) : column
        return "\(subject) \(keyword) (\(rendered.joined(separator: ", ")))"
    }

    public var likeEscapeClause: String {
        switch dialect.likeEscapeStyle {
        case .explicit:
            return " ESCAPE '!'"
        // MySQL's implicit `\` LIKE escape is gone under NO_BACKSLASH_ESCAPES, so it is named.
        case .implicit where dialect.requiresBackslashEscaping && !literalEscapes.backslashEscapes:
            return " ESCAPE '\\'"
        case .implicit:
            return ""
        }
    }

    // The LIKE layer first, with the escape `likeEscapeClause` names, then the literal rule over the whole pattern.
    public func likePatternBody(_ value: String) -> String {
        let escape: Unicode.Scalar = dialect.likeEscapeStyle == .implicit ? "\\" : "!"
        // `[` opens a character class in a SQL Server LIKE pattern.
        let metacharacters: Set<Unicode.Scalar> = databaseType == .mssql ? ["%", "_", "["] : ["%", "_"]
        return literalBody(SQLQuoting.likePattern(value, escape: escape, metacharacters: metacharacters))
    }

    private func quoteIdentifier(_ name: String) -> String {
        if let identifierQuoter { return identifierQuoter(name) }
        switch dialect.identifierQuote {
        case "`":
            return SQLQuoting.identifier(name, quote: .backtick)
        case "[":
            return SQLQuoting.identifier(name, quote: .bracket)
        default:
            return SQLQuoting.identifier(name)
        }
    }

    private func escapeValue(_ value: String, kind: PluginColumnKind?) -> String {
        if FilterColumnKind.isBareNumber(value, kind: kind) {
            return value
        }
        return "'\(literalBody(value))'"
    }

    private func literalBody(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: literalEscapes)
    }
}
