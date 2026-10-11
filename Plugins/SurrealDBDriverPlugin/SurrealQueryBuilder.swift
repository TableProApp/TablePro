//
//  SurrealQueryBuilder.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

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

public struct SurrealFilterRefusal: Error, Equatable, Sendable {
    public let message: String

    public static let incompleteRange = SurrealFilterRefusal(
        message: String(localized: "Enter both bounds to filter with BETWEEN.")
    )

    public static let rawConditionNotReadOnly = SurrealFilterRefusal(
        message: String(
            localized: "A raw SurrealDB filter must be one condition that only reads. Run anything else in the SurrealQL editor."
        )
    )

    public static func unsupportedOperator(_ op: String) -> SurrealFilterRefusal {
        SurrealFilterRefusal(message: String(format: String(localized: "SurrealDB cannot filter rows with %@."), op))
    }

    public var statement: String {
        "THROW " + SurrealQL.stringLiteral(message) + ";"
    }
}

public enum SurrealQueryBuilder {
    public static let rawFilterColumn = "__RAW__"

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
        filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(column: String, ascending: Bool)],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind] = [:]
    ) -> String {
        do throws(SurrealFilterRefusal) {
            let clause = try whereClause(filters: filters, logicMode: logicMode, columnKinds: columnKinds)
            return compose(
                scope: scope,
                statement: select(table: table, where: clause, sortColumns: sortColumns, limit: limit, offset: offset)
            )
        } catch {
            return compose(scope: scope, statement: error.statement)
        }
    }

    public static func count(
        table: String,
        scope: SurrealScope,
        filters: [PluginQueryFilter],
        logicMode: String
    ) -> String {
        do throws(SurrealFilterRefusal) {
            var statement = "SELECT count() AS total FROM " + SurrealQL.quoteIdentifier(table)
            if let clause = try whereClause(filters: filters, logicMode: logicMode) {
                statement += " WHERE " + clause
            }
            statement += " GROUP ALL;"
            return compose(scope: scope, statement: statement)
        } catch {
            return compose(scope: scope, statement: error.statement)
        }
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
        filters: [PluginQueryFilter],
        logicMode: String,
        columnKinds: [String: PluginColumnKind] = [:]
    ) throws(SurrealFilterRefusal) -> String? {
        var conditions: [String] = []
        for filter in filters {
            guard let condition = try condition(filter, kind: columnKinds[filter.column]) else { continue }
            conditions.append(condition)
        }
        guard !conditions.isEmpty else { return nil }
        let separator = logicMode.lowercased() == "or" ? " OR " : " AND "
        return conditions.joined(separator: separator)
    }

    private static func condition(
        _ filter: PluginQueryFilter,
        kind: PluginColumnKind?
    ) throws(SurrealFilterRefusal) -> String? {
        if filter.column == rawFilterColumn {
            return try SurrealRawCondition.parenthesized(filter.value)
        }
        guard !filter.column.isEmpty else { return nil }
        let column = SurrealQL.quoteIdentifier(filter.column)
        let op = filter.op.uppercased().trimmingCharacters(in: .whitespaces)
        let value = filter.value

        switch op {
        case "IS NULL":
            return "(\(column) = NONE OR \(column) = NULL)"
        case "IS NOT NULL":
            return "(\(column) != NONE AND \(column) != NULL)"
        case "IS EMPTY":
            return "(\(column) = NONE OR \(column) = NULL OR \(column) = '')"
        case "IS NOT EMPTY":
            return "(\(column) != NONE AND \(column) != NULL AND \(column) != '')"
        case "CONTAINS":
            return "string::contains(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "NOT CONTAINS":
            return "!string::contains(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "STARTS WITH":
            return "string::starts_with(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "ENDS WITH":
            return "string::ends_with(<string> \(column), \(SurrealQL.stringLiteral(value)))"
        case "REGEX":
            let match = "string::matches(<string> \(column), \(SurrealQL.stringLiteral(value)))"
            return "(\(column) != NONE AND \(column) != NULL AND \(match))"
        case "IN":
            return "\(column) INSIDE \(listLiteral(value, kind: kind))"
        case "NOT IN":
            return "\(column) NOTINSIDE \(listLiteral(value, kind: kind))"
        case "BETWEEN":
            let bounds = try rangeBounds(filter)
            let lower = literal(bounds.lower, kind: kind)
            let upper = literal(bounds.upper, kind: kind)
            return "(\(column) >= \(lower) AND \(column) <= \(upper))"
        case "=", "!=", ">", ">=", "<", "<=":
            return "\(column) \(op) \(literal(value, kind: kind))"
        case "LIKE":
            return "string::contains(<string> \(column), \(SurrealQL.stringLiteral(unwrapWildcards(value))))"
        default:
            throw SurrealFilterRefusal.unsupportedOperator(filter.op)
        }
    }

    private static func rangeBounds(
        _ filter: PluginQueryFilter
    ) throws(SurrealFilterRefusal) -> (lower: String, upper: String) {
        if let upper = filter.secondValue {
            return try completeRange(lower: lowerBound(of: filter.value, upperBound: upper), upper: upper)
        }
        let scalars = filter.value.unicodeScalars
        guard let separator = scalars.firstIndex(of: ",") else { throw .incompleteRange }
        return try completeRange(
            lower: String(scalars[..<separator]),
            upper: String(scalars[scalars.index(after: separator)...])
        )
    }

    private static func lowerBound(of joinedValue: String, upperBound: String) -> String {
        let joinedSuffix = ("," + upperBound).unicodeScalars
        let scalars = joinedValue.unicodeScalars
        guard scalars.reversed().starts(with: joinedSuffix.reversed()) else { return joinedValue }
        return String(scalars.dropLast(joinedSuffix.count))
    }

    private static func completeRange(
        lower: String,
        upper: String
    ) throws(SurrealFilterRefusal) -> (lower: String, upper: String) {
        let lowerBound = lower.trimmingCharacters(in: .whitespaces)
        let upperBound = upper.trimmingCharacters(in: .whitespaces)
        guard !lowerBound.isEmpty, !upperBound.isEmpty else { throw .incompleteRange }
        return (lowerBound, upperBound)
    }

    private static func listLiteral(_ value: String, kind: PluginColumnKind?) -> String {
        let items = value
            .split(separator: ",")
            .map { literal($0.trimmingCharacters(in: .whitespaces), kind: kind) }
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

    public static func literal(_ value: String, kind: PluginColumnKind?) -> String {
        guard let kind else { return literal(value) }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if !PluginSQLLiteral.isKnownTextLike(kind) {
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
            if PluginSQLLiteral.isNumericLiteral(trimmed, kind: kind) {
                return trimmed
            }
        }
        if let record = recordLiteral(trimmed) {
            return record
        }
        return SurrealQL.stringLiteral(value)
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
