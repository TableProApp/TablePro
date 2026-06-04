import Foundation
import TableProModels

public struct FilterSQLGenerator: Sendable {
    private let dialect: QueryDialectDescriptor

    public init(dialect: QueryDialectDescriptor) {
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

        switch filter.filterOperator {
        case .equal:
            if escapedValue == "NULL" { return "\(quotedColumn) IS NULL" }
            return "\(quotedColumn) = \(escapedValue)"
        case .notEqual:
            if escapedValue == "NULL" { return "\(quotedColumn) IS NOT NULL" }
            return "\(quotedColumn) != \(escapedValue)"
        case .greaterThan:
            return "\(quotedColumn) > \(escapedValue)"
        case .greaterThanOrEqual:
            return "\(quotedColumn) >= \(escapedValue)"
        case .lessThan:
            return "\(quotedColumn) < \(escapedValue)"
        case .lessThanOrEqual:
            return "\(quotedColumn) <= \(escapedValue)"
        case .like:
            return "\(quotedColumn) LIKE \(dialect.sqlLiteral(for: filter.value, interpretSpecialLiterals: false))\(likeEscape)"
        case .notLike:
            return "\(quotedColumn) NOT LIKE \(dialect.sqlLiteral(for: filter.value, interpretSpecialLiterals: false))\(likeEscape)"
        case .isNull:
            return "\(quotedColumn) IS NULL"
        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"
        case .in:
            let values = parseInValues(filter.value)
            return "\(quotedColumn) IN (\(values))"
        case .notIn:
            let values = parseInValues(filter.value)
            return "\(quotedColumn) NOT IN (\(values))"
        case .between:
            let escapedSecond = escapeValue(filter.secondValue)
            return "\(quotedColumn) BETWEEN \(escapedValue) AND \(escapedSecond)"
        case .contains:
            let pattern = escapeLikePattern(filter.value)
            return "\(quotedColumn) LIKE '%\(pattern)%'\(likeEscape)"
        case .startsWith:
            let pattern = escapeLikePattern(filter.value)
            return "\(quotedColumn) LIKE '\(pattern)%'\(likeEscape)"
        case .endsWith:
            let pattern = escapeLikePattern(filter.value)
            return "\(quotedColumn) LIKE '%\(pattern)'\(likeEscape)"
        }
    }

    private var likeEscape: String {
        dialect.likeEscapeClause
    }

    private func quoteIdentifier(_ name: String) -> String {
        dialect.quoteIdentifier(name)
    }

    private func escapeValue(_ value: String) -> String {
        dialect.sqlLiteral(for: value)
    }

    private func escapeLikePattern(_ value: String) -> String {
        dialect.escapeLikeWildcards(value)
    }

    private func parseInValues(_ value: String) -> String {
        let parts = value.components(separatedBy: ",")
        return parts.map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return escapeValue(trimmed)
        }.joined(separator: ", ")
    }
}
