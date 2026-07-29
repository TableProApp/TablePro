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

        switch filter.filterOperator {
        case .equal:
            return "\(quotedColumn) = \(escapedValue)"
        case .notEqual:
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
            return "\(quotedColumn) LIKE \(escapedValue)\(likeEscape)"
        case .notLike:
            return "\(quotedColumn) NOT LIKE \(escapedValue)\(likeEscape)"
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

    private func parseInValues(_ value: String) -> String {
        let parts = value.components(separatedBy: ",")
        return parts.map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return escapeValue(trimmed)
        }.joined(separator: ", ")
    }
}
