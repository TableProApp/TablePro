import Foundation
import TableProModels
import TableProPluginKit

public struct FilterSQLGenerator: Sendable {
    private let dialect: SQLDialectDescriptor

    public init(dialect: SQLDialectDescriptor) {
        self.dialect = dialect
    }

    public func generateWhereClause(
        from filters: [TableFilter],
        logicMode: FilterLogicMode
    ) -> String {
        let activeFilters = filters.filter { $0.isEnabled && $0.isValid }
        guard !activeFilters.isEmpty else { return "" }

        let conditions = activeFilters.compactMap { generateCondition(for: $0) }
        guard !conditions.isEmpty else { return "" }

        let joined = conditions.joined(separator: " \(logicMode.rawValue) ")
        return "WHERE \(joined)"
    }

    private func generateCondition(for filter: TableFilter) -> String? {
        if filter.columnName == TableFilter.rawSQLColumn {
            guard let rawSQL = filter.rawSQL, !rawSQL.isEmpty else { return nil }
            return rawSQL
        }

        let quotedColumn = quoteIdentifier(filter.columnName)
        let escapedValue = escapeValue(filter.value)
        let folding = caseFolding(for: filter)

        switch filter.filterOperator {
        case .equal:
            return comparisonCondition(quotedColumn, "=", escapedValue, folding: folding)
        case .notEqual:
            return comparisonCondition(quotedColumn, "!=", escapedValue, folding: folding)
        case .greaterThan:
            return "\(quotedColumn) > \(escapedValue)"
        case .greaterThanOrEqual:
            return "\(quotedColumn) >= \(escapedValue)"
        case .lessThan:
            return "\(quotedColumn) < \(escapedValue)"
        case .lessThanOrEqual:
            return "\(quotedColumn) <= \(escapedValue)"
        case .like:
            return likeCondition(quotedColumn, escapedValue, negated: false, folding: folding)
        case .notLike:
            return likeCondition(quotedColumn, escapedValue, negated: true, folding: folding)
        case .isNull:
            return "\(quotedColumn) IS NULL"
        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"
        case .in:
            return listCondition(quotedColumn, filter.value, negated: false, folding: folding)
        case .notIn:
            return listCondition(quotedColumn, filter.value, negated: true, folding: folding)
        case .between:
            let escapedSecond = escapeValue(filter.secondValue)
            return "\(quotedColumn) BETWEEN \(escapedValue) AND \(escapedSecond)"
        case .contains:
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(quotedColumn, "'%\(pattern)%'", negated: false, folding: folding)
        case .startsWith:
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(quotedColumn, "'\(pattern)%'", negated: false, folding: folding)
        case .endsWith:
            let pattern = escapeLikePattern(filter.value)
            return likeCondition(quotedColumn, "'%\(pattern)'", negated: false, folding: folding)
        }
    }

    private func caseFolding(for filter: TableFilter) -> PluginSQLCaseFolding {
        PluginSQLCaseFolding.resolve(
            style: dialect.caseSensitivityStyle,
            foldFunction: dialect.caseFoldFunction,
            isCaseSensitive: filter.isCaseSensitive || !filter.filterOperator.supportsCaseSensitivity
        )
    }

    private func comparisonCondition(
        _ column: String, _ operatorText: String, _ literal: String, folding: PluginSQLCaseFolding
    ) -> String {
        guard folding.foldsComparisonOperands, literal.hasPrefix("'") else {
            return "\(column) \(operatorText) \(literal)"
        }
        return "\(folding.fold(column)) \(operatorText) \(folding.fold(literal))"
    }

    private func likeCondition(
        _ column: String, _ pattern: String, negated: Bool, folding: PluginSQLCaseFolding
    ) -> String {
        let keyword = negated ? folding.notLikeKeyword : folding.likeKeyword
        return "\(folding.foldingLikeOperand(column)) \(keyword) \(folding.foldingLikeOperand(pattern))\(likeEscape)"
    }

    private func listCondition(
        _ column: String, _ rawValue: String, negated: Bool, folding: PluginSQLCaseFolding
    ) -> String {
        let keyword = negated ? "NOT IN" : "IN"
        let items = rawValue.split(separator: ",")
            .map { escapeValue($0.trimmingCharacters(in: .whitespaces)) }
        let foldable = folding.foldsComparisonOperands && items.allSatisfy { $0.hasPrefix("'") }
        let rendered = foldable ? items.map { folding.fold($0) } : items
        let subject = foldable ? folding.fold(column) : column
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
        let q = dialect.identifierQuote
        let escaped = name.replacingOccurrences(of: q, with: "\(q)\(q)")
        return "\(q)\(escaped)\(q)"
    }

    private func escapeValue(_ value: String) -> String {
        if Int64(value) != nil || Double(value) != nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\0", with: "")
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
