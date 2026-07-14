//
//  SurrealQueryBuilder.swift
//  SurrealDBDriverPlugin
//

import Foundation

public struct SurrealScope: Equatable, Sendable {
    public let namespace: String?
    public let database: String?

    public init(namespace: String?, database: String?) {
        self.namespace = namespace?.isEmpty == true ? nil : namespace
        self.database = database?.isEmpty == true ? nil : database
    }

    public var useStatement: String? {
        var clause = ""
        if let namespace {
            clause += " NS " + SurrealQL.quoteIdentifier(namespace)
        }
        if let database {
            clause += " DB " + SurrealQL.quoteIdentifier(database)
        }
        guard !clause.isEmpty else { return nil }
        return "USE" + clause + ";"
    }
}

public enum SurrealQueryBuilder {
    public static func browse(
        table: String,
        scope: SurrealScope,
        sortColumns: [(column: String, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        compose(scope: scope, statement: select(table: table, where: nil, sortColumns: sortColumns, limit: limit, offset: offset))
    }

    public static func filtered(
        table: String,
        scope: SurrealScope,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(column: String, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let clause = whereClause(filters: filters, logicMode: logicMode)
        return compose(
            scope: scope,
            statement: select(table: table, where: clause, sortColumns: sortColumns, limit: limit, offset: offset)
        )
    }

    public static func count(
        table: String,
        scope: SurrealScope,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String {
        var statement = "SELECT count() AS total FROM " + SurrealQL.quoteIdentifier(table)
        if let clause = whereClause(filters: filters, logicMode: logicMode) {
            statement += " WHERE " + clause
        }
        statement += " GROUP ALL;"
        return compose(scope: scope, statement: statement)
    }

    public static func sample(table: String, scope: SurrealScope, limit: Int) -> String {
        compose(
            scope: scope,
            statement: "SELECT * FROM " + SurrealQL.quoteIdentifier(table) + " LIMIT \(max(1, limit));"
        )
    }

    public static func compose(scope: SurrealScope, statement: String) -> String {
        guard let use = scope.useStatement else { return statement }
        return use + "\n" + statement
    }

    // MARK: - Statement pieces

    private static func select(
        table: String,
        where clause: String?,
        sortColumns: [(column: String, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        var statement = "SELECT * FROM " + SurrealQL.quoteIdentifier(table)
        if let clause {
            statement += " WHERE " + clause
        }
        statement += " ORDER BY " + orderBy(sortColumns)
        statement += " LIMIT \(max(1, limit))"
        if offset > 0 {
            statement += " START \(offset)"
        }
        return statement + ";"
    }

    private static func orderBy(_ sortColumns: [(column: String, ascending: Bool)]) -> String {
        let sorts = sortColumns
            .filter { !$0.column.isEmpty }
            .map { SurrealQL.quoteIdentifier($0.column) + ($0.ascending ? " ASC" : " DESC") }
        guard !sorts.isEmpty else { return "id ASC" }
        return (sorts + ["id ASC"]).joined(separator: ", ")
    }

    public static func whereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String? {
        let conditions = filters.compactMap(condition)
        guard !conditions.isEmpty else { return nil }
        let separator = logicMode.lowercased() == "or" ? " OR " : " AND "
        return conditions.joined(separator: separator)
    }

    private static func condition(_ filter: (column: String, op: String, value: String)) -> String? {
        guard !filter.column.isEmpty else { return nil }
        let column = SurrealQL.quoteIdentifier(filter.column)
        let op = filter.op.uppercased().trimmingCharacters(in: .whitespaces)
        let value = filter.value

        switch op {
        case "IS NULL":
            return "(\(column) = NONE OR \(column) = NULL)"
        case "IS NOT NULL":
            return "(\(column) != NONE AND \(column) != NULL)"
        case "CONTAINS":
            return "string::contains(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "NOT CONTAINS":
            return "!string::contains(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "STARTS WITH":
            return "string::starts_with(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "ENDS WITH":
            return "string::ends_with(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "IN":
            return "\(column) INSIDE \(listLiteral(value))"
        case "NOT IN":
            return "\(column) NOTINSIDE \(listLiteral(value))"
        case "=", "!=", ">", ">=", "<", "<=":
            return "\(column) \(op) \(literal(value))"
        case "LIKE":
            return "string::contains(<string> \(column), \(SurrealQL.stringLiteral(unwrapWildcards(value))))"
        default:
            return "\(column) = \(literal(value))"
        }
    }

    private static func listLiteral(_ value: String) -> String {
        let items = value
            .split(separator: ",")
            .map { literal($0.trimmingCharacters(in: .whitespaces)) }
        return "[" + items.joined(separator: ", ") + "]"
    }

    private static func unwrapWildcards(_ value: String) -> String {
        var text = value
        if text.hasPrefix("%") {
            text.removeFirst()
        }
        if text.hasSuffix("%") {
            text.removeLast()
        }
        return text
    }

    public static func literal(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        if lowered == "null" {
            return "NULL"
        }
        if lowered == "none" {
            return "NONE"
        }
        if lowered == "true" || lowered == "false" {
            return lowered
        }
        if isNumeric(trimmed) {
            return trimmed
        }
        if let record = recordLiteral(trimmed) {
            return record
        }
        return SurrealQL.stringLiteral(value)
    }

    private static func recordLiteral(_ value: String) -> String? {
        guard !value.contains(" "), looksLikeRecordId(value) else { return nil }
        guard let record = SurrealQL.parseRecordId(value) else { return nil }
        return SurrealQL.recordLiteral(record)
    }

    private static func looksLikeRecordId(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { return false }
        let table = value[value.startIndex..<colon]
        guard let first = table.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return table.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        } && value.index(after: colon) < value.endIndex
    }

    private static func isNumeric(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if Int64(value) != nil { return true }
        guard Double(value) != nil else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
    }
}
