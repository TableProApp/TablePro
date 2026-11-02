import Foundation

public enum PluginSQLFilter {
    public static func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "%", with: "\\%", options: .literal)
            .replacingOccurrences(of: "_", with: "\\_", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
    }

    public static func buildOrderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        quoteIdentifier: (String) -> String
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let direction = sortCol.ascending ? "ASC" : "DESC"
            return "\(quoteIdentifier(columns[sortCol.columnIndex])) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    public static func buildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                quoteIdentifier: quoteIdentifier,
                escapeValue: escapeValue,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    public static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        let quoted = quoteIdentifier(column)
        switch op {
        case "=": return "\(quoted) = \(escapeValue(value))"
        case "!=": return "\(quoted) != \(escapeValue(value))"
        case ">": return "\(quoted) > \(escapeValue(value))"
        case ">=": return "\(quoted) >= \(escapeValue(value))"
        case "<": return "\(quoted) < \(escapeValue(value))"
        case "<=": return "\(quoted) <= \(escapeValue(value))"
        case "IS NULL": return "\(quoted) IS NULL"
        case "IS NOT NULL": return "\(quoted) IS NOT NULL"
        case "IS EMPTY": return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY": return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        case "CONTAINS":
            return "\(quoted) LIKE '%\(escapeForLike(value))%' ESCAPE '\\'"
        case "NOT CONTAINS":
            return "\(quoted) NOT LIKE '%\(escapeForLike(value))%' ESCAPE '\\'"
        case "STARTS WITH":
            return "\(quoted) LIKE '\(escapeForLike(value))%' ESCAPE '\\'"
        case "ENDS WITH":
            return "\(quoted) LIKE '%\(escapeForLike(value))' ESCAPE '\\'"
        case "IN":
            let values = value.split(separator: ",")
                .map { escapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) IN (\(values))"
        case "NOT IN":
            let values = value.split(separator: ",")
                .map { escapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) NOT IN (\(values))"
        case "BETWEEN":
            let parts = value.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let v1 = escapeValue(parts[0].trimmingCharacters(in: .whitespaces))
            let v2 = escapeValue(parts[1].trimmingCharacters(in: .whitespaces))
            return "\(quoted) BETWEEN \(v1) AND \(v2)"
        case "REGEX":
            return regexCondition(quoted, value)
        default: return nil
        }
    }

    public static func buildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        columnKinds: [String: PluginColumnKind],
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                kind: columnKinds[filter.column],
                quoteIdentifier: quoteIdentifier,
                escapeTypedValue: escapeTypedValue,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    public static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        kind: PluginColumnKind?,
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        let quoted = quoteIdentifier(column)
        switch op {
        case "IS EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(quoted) IS NULL" }
            return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(quoted) IS NOT NULL" }
            return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        default:
            return buildFilterCondition(
                column: column,
                op: op,
                value: value,
                quoteIdentifier: quoteIdentifier,
                escapeValue: { escapeTypedValue($0, kind) },
                regexCondition: regexCondition
            )
        }
    }
}
