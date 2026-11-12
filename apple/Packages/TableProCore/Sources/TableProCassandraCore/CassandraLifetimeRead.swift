//
//  CassandraLifetimeRead.swift
//  TableProCassandraCore
//

import Foundation

// The browse the plugin sends with a TTL() selector after the shown columns for each one that can carry its own
// TTL. `SELECT *` takes no other selector, so it is spelled out in the order the server returns it.
public enum CassandraLifetimeRead {
    public struct Plan: Equatable, Sendable {
        public let cql: String
        public let shownColumns: [String]
        // The column of each TTL() selector, in the order the selectors follow the shown columns.
        public let lifetimeColumns: [String]
        public let lifetimeValueIndices: [Int]
        public let keyIndices: [String: Int]
    }

    // Nil unless `cql` is a browse of `target` as the renderer writes it, every key column is shown, and at least one
    // shown column takes a TTL() selector.
    public static func plan(cql: String, target: String, layout: CassandraTableLayout) -> Plan? {
        guard let select = select(of: cql, target: target) else { return nil }
        let shown = select.columns ?? layout.selectOrder
        var lifetimeColumns: [String] = []
        var lifetimeValueIndices: [Int] = []
        for (index, column) in shown.enumerated()
            where layout.acceptsTimeToLive(column) && !lifetimeColumns.contains(column) {
            lifetimeColumns.append(column)
            lifetimeValueIndices.append(index)
        }
        guard !lifetimeColumns.isEmpty else { return nil }
        var keyIndices: [String: Int] = [:]
        for key in layout.primaryKey {
            guard let index = shown.firstIndex(of: key) else { return nil }
            keyIndices[key] = index
        }
        let selectors = shown.map(CassandraObjectQueries.quote)
            + lifetimeColumns.map { "TTL(\(CassandraObjectQueries.quote($0)))" }
        return Plan(
            cql: "SELECT \(selectors.joined(separator: ", ")) FROM \(target)\(select.tail)",
            shownColumns: shown,
            lifetimeColumns: lifetimeColumns,
            lifetimeValueIndices: lifetimeValueIndices,
            keyIndices: keyIndices
        )
    }

    private struct Select {
        // Nil for `*`.
        let columns: [String]?
        let tail: String
    }

    private static func select(of cql: String, target: String) -> Select? {
        var rest = Substring(cql).unicodeScalars
        guard consume("SELECT ", from: &rest) else { return nil }
        var columns: [String]?
        if !consume("* ", from: &rest) {
            var names: [String] = []
            repeat {
                guard let name = quotedName(from: &rest) else { return nil }
                names.append(name)
            } while consume(", ", from: &rest)
            guard consume(" ", from: &rest) else { return nil }
            columns = names
        }
        guard consume("FROM " + target, from: &rest) else { return nil }
        let tail = String(Substring(rest))
        guard tail.isEmpty || tail.hasPrefix(" WHERE ") else { return nil }
        return Select(columns: columns, tail: tail)
    }

    private static func consume(_ text: String, from rest: inout Substring.UnicodeScalarView) -> Bool {
        guard rest.starts(with: text.unicodeScalars) else { return false }
        rest = rest.dropFirst(text.unicodeScalars.count)
        return true
    }

    // A double-quoted identifier, `""` standing for one quote, as SQLQuoting.identifier writes it.
    private static func quotedName(from rest: inout Substring.UnicodeScalarView) -> String? {
        guard consume("\"", from: &rest) else { return nil }
        var name = String.UnicodeScalarView()
        while let scalar = rest.first {
            rest = rest.dropFirst()
            guard scalar == "\"" else {
                name.append(scalar)
                continue
            }
            guard consume("\"", from: &rest) else { return String(name) }
            name.append(scalar)
        }
        return nil
    }
}
