import Foundation

public struct R2SQLSortColumn: Sendable, Equatable {
    public let name: String
    public let ascending: Bool

    public init(name: String, ascending: Bool) {
        self.name = name
        self.ascending = ascending
    }
}

public struct R2SQLFilter: Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String

    public init(column: String, op: String, value: String) {
        self.column = column
        self.op = op
        self.value = value
    }
}

public enum R2SQLQueryBuilder {
    public static func selectList(_ columns: [String]) -> String {
        guard !columns.isEmpty else { return "*" }
        return columns.map(R2SQLLiteral.quoteIdentifier).joined(separator: ", ")
    }

    public static func orderByClause(_ sortColumns: [R2SQLSortColumn]) -> String? {
        let parts = sortColumns
            .filter { !$0.name.isEmpty }
            .map { R2SQLLiteral.quoteIdentifier($0.name) + ($0.ascending ? " ASC" : " DESC") }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    public static func browseQuery(
        namespace: String,
        table: String,
        columns: [String] = [],
        sortColumns: [R2SQLSortColumn] = [],
        limit: Int
    ) -> String {
        compose(
            namespace: namespace,
            table: table,
            columns: columns,
            whereClause: nil,
            sortColumns: sortColumns,
            limit: limit
        )
    }

    public static func filteredQuery(
        namespace: String,
        table: String,
        filters: [R2SQLFilter],
        matchAll: Bool,
        columns: [String] = [],
        sortColumns: [R2SQLSortColumn] = [],
        limit: Int
    ) -> String {
        compose(
            namespace: namespace,
            table: table,
            columns: columns,
            whereClause: whereClause(filters: filters, matchAll: matchAll),
            sortColumns: sortColumns,
            limit: limit
        )
    }

    public static func countQuery(
        namespace: String,
        table: String,
        filters: [R2SQLFilter] = [],
        matchAll: Bool = true
    ) -> String {
        var sql = "SELECT COUNT(*) AS total FROM \(R2SQLLiteral.qualifiedName(namespace: namespace, table: table))"
        if let clause = whereClause(filters: filters, matchAll: matchAll) {
            sql += " WHERE \(clause)"
        }
        return sql
    }

    public static func whereClause(filters: [R2SQLFilter], matchAll: Bool) -> String? {
        let parts = filters.compactMap(predicate(for:))
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: matchAll ? " AND " : " OR ")
    }

    private static func compose(
        namespace: String,
        table: String,
        columns: [String],
        whereClause: String?,
        sortColumns: [R2SQLSortColumn],
        limit: Int
    ) -> String {
        var sql = "SELECT \(selectList(columns))"
        sql += " FROM \(R2SQLLiteral.qualifiedName(namespace: namespace, table: table))"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        if let orderBy = orderByClause(sortColumns) {
            sql += " \(orderBy)"
        }
        sql += " LIMIT \(R2SQLLimits.clampLimit(limit))"
        return sql
    }

    private static func predicate(for filter: R2SQLFilter) -> String? {
        let column = filter.column.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !column.isEmpty else { return nil }
        let quoted = R2SQLLiteral.quoteIdentifier(column)
        let op = filter.op.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch op {
        case "IS NULL", "ISNULL":
            return "\(quoted) IS NULL"
        case "IS NOT NULL", "NOTNULL":
            return "\(quoted) IS NOT NULL"
        case "CONTAINS":
            return "\(quoted) LIKE \(R2SQLLiteral.stringLiteral("%\(filter.value)%"))"
        case "STARTS WITH", "BEGINS WITH":
            return "\(quoted) LIKE \(R2SQLLiteral.stringLiteral("\(filter.value)%"))"
        case "ENDS WITH":
            return "\(quoted) LIKE \(R2SQLLiteral.stringLiteral("%\(filter.value)"))"
        case "IN", "NOT IN":
            return listPredicate(quoted: quoted, op: op, value: filter.value)
        case "=", "!=", "<>", "<", "<=", ">", ">=", "LIKE", "NOT LIKE":
            return "\(quoted) \(op) \(literal(for: filter.value))"
        default:
            return nil
        }
    }

    private static func listPredicate(quoted: String, op: String, value: String) -> String? {
        let items = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        let rendered = items.map(literal(for:)).joined(separator: ", ")
        return "\(quoted) \(op) (\(rendered))"
    }

    private static func literal(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "true" || lowered == "false" {
            return lowered
        }
        if lowered == "null" {
            return "NULL"
        }
        if isNumeric(trimmed) {
            return trimmed
        }
        return R2SQLLiteral.stringLiteral(value)
    }

    private static func isNumeric(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return Double(text) != nil && text.allSatisfy { $0.isNumber || "+-.eE".contains($0) }
    }
}
