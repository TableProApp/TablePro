import Foundation
import TableProCoreTypes
import TableProModels
import TableProPluginKit

public struct FilterSQLGenerator: Sendable {
    private let dialect: SQLDialectDescriptor
    private let databaseType: DatabaseType?

    public init(dialect: SQLDialectDescriptor, databaseType: DatabaseType? = nil) {
        self.dialect = dialect
        self.databaseType = databaseType
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
        let folding = caseFolding(for: filter)
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
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(operand, "'%\(pattern)%'", negated: false, folding: folding)
        case .startsWith:
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(operand, "'\(pattern)%'", negated: false, folding: folding)
        case .endsWith:
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(operand, "'%\(pattern)'", negated: false, folding: folding)
        }
    }

    private func caseFolding(for filter: TableFilter) -> PluginSQLCaseFolding {
        PluginSQLCaseFolding.resolve(
            style: dialect.caseSensitivityStyle,
            foldFunction: dialect.caseFoldFunction,
            isCaseSensitive: filter.isCaseSensitive || !filter.filterOperator.supportsCaseSensitivity
        )
    }

    // A plain comparison keeps the column's own type and its index; only a case fold reads it as text.
    private func comparisonCondition(
        _ column: String, _ operand: String, _ operatorText: String, _ literal: String, folding: PluginSQLCaseFolding
    ) -> String {
        guard folding.foldsComparisonOperands, literal.hasPrefix("'") else {
            return "\(column) \(operatorText) \(literal)"
        }
        return "\(folding.fold(operand)) \(operatorText) \(folding.fold(literal))"
    }

    private func eitherStorageComparison(_ column: String, _ value: String, negated: Bool) -> String {
        guard FilterColumnKind.isCanonicalSQLiteNumber(value) else {
            return "\(column) \(negated ? "!=" : "=") \(escapeValue(value, kind: .text))"
        }
        return eitherStorageList(column, [value], negated: negated)
    }

    private func eitherStorageList(_ column: String, _ values: [String], negated: Bool) -> String {
        let literals = values.flatMap { value -> [String] in
            let quoted = escapeValue(value, kind: .text)
            return FilterColumnKind.isCanonicalSQLiteNumber(value) ? [value, quoted] : [quoted]
        }
        return "\(column) \(negated ? "NOT IN" : "IN") (\(literals.joined(separator: ", ")))"
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
        return "\(folding.foldingLikeOperand(column)) \(keyword) \(folding.foldingLikeOperand(pattern))\(likeEscape)"
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
        let foldable = folding.foldsComparisonOperands && items.allSatisfy { $0.hasPrefix("'") }
        let rendered = foldable ? items.map { folding.fold($0) } : items
        let subject = foldable ? folding.fold(operand) : column
        return "\(subject) \(keyword) (\(rendered.joined(separator: ", ")))"
    }

    private var likeEscape: String {
        switch dialect.likeEscapeStyle {
        case .explicit:
            return " ESCAPE '!'"
        case .implicit:
            return ""
        }
    }

    private func quoteIdentifier(_ name: String) -> String {
        let open = dialect.identifierQuote
        let close = open == "[" ? "]" : open
        let escaped = name.replacingOccurrences(of: close, with: "\(close)\(close)")
        return "\(open)\(escaped)\(close)"
    }

    private func escapeValue(_ value: String, kind: PluginColumnKind?) -> String {
        if FilterColumnKind.isBareNumber(value, kind: kind) {
            return value
        }
        var escaped = value.replacingOccurrences(of: "\0", with: "")
        if dialect.requiresBackslashEscaping {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        escaped = escaped.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private func escapeLikePattern(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\0", with: "")
        switch dialect.likeEscapeStyle {
        case .explicit:
            result = result
                .replacingOccurrences(of: "!", with: "!!")
                .replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_")
        case .implicit:
            if dialect.requiresBackslashEscaping {
                result = result.replacingOccurrences(of: "\\", with: "\\\\")
            }
            result = result
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        }
        return result
    }
}
