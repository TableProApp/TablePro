//
//  CassandraBrowseStatement.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

/// A table browse the plugin builds and runs itself, written as the CQL it sends behind a comment that carries what
/// CQL cannot say: which rows of the result to show and the values for its bind markers.
///
/// CQL has no OFFSET, so a page past the first is reached by walking the driver's paging state, and a filter value
/// is bound by the type its column has, which only the prepared statement knows. The statement stays readable in
/// history and still runs as plain CQL anywhere else, where the comment is ignored.
struct CassandraBrowseStatement: Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let offset: Int
        let limit: Int
        let values: [String]
        let refusal: String?
    }

    static let opening = "/* TablePro browse "
    static let closing = " */ "

    let window: Window
    let cql: String

    var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = (try? encoder.encode(window)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Self.opening + header + Self.closing + cql
    }

    /// The same browse read one row past a query tab's cap, so a result the cap trims is still reported as trimmed.
    func cappedAt(rowCap: Int) -> CassandraBrowseStatement {
        let limit = min(window.limit, rowCap + 1)
        return CassandraBrowseStatement(
            window: Window(offset: window.offset, limit: limit, values: window.values, refusal: window.refusal),
            cql: cql
        )
    }

    static func parse(_ text: String) -> CassandraBrowseStatement? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(opening),
              let end = trimmed.range(of: "*/", range: trimmed.index(trimmed.startIndex, offsetBy: opening.count)..<trimmed.endIndex)
        else { return nil }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: opening.count)..<end.lowerBound]
        guard let data = header.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let window = try? JSONDecoder().decode(Window.self, from: data)
        else { return nil }
        let cql = trimmed[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return CassandraBrowseStatement(window: window, cql: cql)
    }
}

struct CassandraBrowseRefusal: Error, Equatable, PluginDriverError {
    let pluginErrorMessage: String

    static let sorting = CassandraBrowseRefusal(pluginErrorMessage: String(
        localized: "Cassandra orders rows only by clustering columns within one partition, so a table cannot be sorted by a column."
    ))

    static let matchAny = CassandraBrowseRefusal(pluginErrorMessage: String(
        localized: "Cassandra filters can only require every condition to match."
    ))

    static let emptyList = CassandraBrowseRefusal(pluginErrorMessage: String(
        localized: "Enter at least one value to filter with IN."
    ))

    static let incompleteRange = CassandraBrowseRefusal(pluginErrorMessage: String(
        localized: "Enter both bounds to filter with BETWEEN."
    ))

    static func unsupportedOperator(_ op: String) -> CassandraBrowseRefusal {
        CassandraBrowseRefusal(pluginErrorMessage: String(
            format: String(localized: "Cassandra cannot filter rows with %@."), op
        ))
    }
}

enum CassandraBrowseRenderer {
    struct Condition: Equatable {
        let cql: String
        let values: [String]
    }

    static let rawFilterColumn = "__RAW__"

    static func browse(
        keyspace: String?,
        table: String,
        columns: [String],
        filters: [PluginQueryFilter],
        matchAll: Bool,
        sorted: Bool,
        limit: Int,
        offset: Int
    ) -> CassandraBrowseStatement {
        let selectList = columns.isEmpty ? "*" : columns.map(quote).joined(separator: ", ")
        let source = "SELECT \(selectList) FROM \(qualifiedTable(keyspace: keyspace, table: table))"
        do {
            if sorted { throw CassandraBrowseRefusal.sorting }
            let condition = try whereCondition(filters: filters, matchAll: matchAll)
            return CassandraBrowseStatement(
                window: .init(offset: max(offset, 0), limit: max(limit, 0), values: condition.values, refusal: nil),
                cql: appending(condition, to: source)
            )
        } catch {
            let message = (error as? CassandraBrowseRefusal)?.pluginErrorMessage ?? error.localizedDescription
            return CassandraBrowseStatement(
                window: .init(offset: max(offset, 0), limit: max(limit, 0), values: [], refusal: message),
                cql: source
            )
        }
    }

    static func count(
        keyspace: String?,
        table: String,
        filters: [PluginQueryFilter],
        matchAll: Bool
    ) throws -> Condition {
        let condition = try whereCondition(filters: filters, matchAll: matchAll)
        let source = "SELECT COUNT(*) FROM \(qualifiedTable(keyspace: keyspace, table: table))"
        return Condition(cql: appending(condition, to: source), values: condition.values)
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func qualifiedTable(keyspace: String?, table: String) -> String {
        guard let keyspace, !keyspace.isEmpty else { return quote(table) }
        return quote(keyspace) + "." + quote(table)
    }

    /// `ALLOW FILTERING` is the last clause CQL accepts, so it goes after everything else, and it goes on whenever
    /// there is a condition, because a condition on anything but the whole partition key is refused without it.
    private static func appending(_ condition: Condition, to source: String) -> String {
        guard !condition.cql.isEmpty else { return source }
        return "\(source) WHERE \(condition.cql) ALLOW FILTERING"
    }

    static func whereCondition(filters: [PluginQueryFilter], matchAll: Bool) throws -> Condition {
        guard !filters.isEmpty else { return Condition(cql: "", values: []) }
        if !matchAll, filters.count > 1 { throw CassandraBrowseRefusal.matchAny }
        let conditions = try filters.map(condition)
        return Condition(
            cql: conditions.map(\.cql).joined(separator: " AND "),
            values: conditions.flatMap(\.values)
        )
    }

    private static func condition(_ filter: PluginQueryFilter) throws -> Condition {
        if filter.column == rawFilterColumn {
            let raw = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw CassandraBrowseRefusal.unsupportedOperator(filter.op) }
            return Condition(cql: raw, values: [])
        }
        let column = quote(filter.column)
        switch filter.op.uppercased() {
        case "=", ">", ">=", "<", "<=":
            return Condition(cql: "\(column) \(filter.op) ?", values: [filter.value])
        case "CONTAINS":
            return Condition(cql: "\(column) LIKE ?", values: ["%" + likeLiteral(filter.value) + "%"])
        case "STARTS WITH":
            return Condition(cql: "\(column) LIKE ?", values: [likeLiteral(filter.value) + "%"])
        case "ENDS WITH":
            return Condition(cql: "\(column) LIKE ?", values: ["%" + likeLiteral(filter.value)])
        case "IN":
            let items = listItems(filter.value)
            guard !items.isEmpty else { throw CassandraBrowseRefusal.emptyList }
            let markers = Array(repeating: "?", count: items.count).joined(separator: ", ")
            return Condition(cql: "\(column) IN (\(markers))", values: items)
        case "BETWEEN":
            let bounds = try rangeBounds(filter)
            return Condition(cql: "\(column) >= ? AND \(column) <= ?", values: [bounds.lower, bounds.upper])
        default:
            throw CassandraBrowseRefusal.unsupportedOperator(filter.op)
        }
    }

    /// ScyllaDB reads `%` and `_` in a `LIKE` pattern as wildcards and a backslash as their escape, measured, so a
    /// value holding either would otherwise match text it does not contain.
    static func likeLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "%" || scalar == "_" {
                escaped.unicodeScalars.append("\\")
            }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }

    private static func listItems(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func rangeBounds(_ filter: PluginQueryFilter) throws -> (lower: String, upper: String) {
        if let upper = filter.secondValue, !upper.isEmpty {
            let joinedSuffix = "," + upper
            let lower = filter.value.hasSuffix(joinedSuffix)
                ? String(filter.value.dropLast(joinedSuffix.count))
                : filter.value
            guard !lower.isEmpty else { throw CassandraBrowseRefusal.incompleteRange }
            return (lower, upper)
        }
        let parts = filter.value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw CassandraBrowseRefusal.incompleteRange }
        return (String(parts[0]), String(parts[1]))
    }
}
