//
//  RedisQueryBuilder.swift
//  RedisDriverPlugin
//
//  Builds Redis command strings for key browsing and filtering.
//  Plugin-local version using primitive types instead of Core types.
//

import Foundation
import TableProPluginKit

struct RedisQueryBuilder {
    // MARK: - Base Query

    /// Build a SCAN command for browsing keys in a namespace.
    /// Returns: SCAN 0 MATCH namespace:* COUNT limit
    func buildBaseQuery(
        namespace: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let pattern = namespace.isEmpty ? "*" : "\(namespace)*"
        return "SCAN 0 MATCH \"\(pattern)\" COUNT \(limit)"
    }

    /// Build a SCAN command with filters applied.
    /// Redis does not support server-side filtering beyond pattern matching;
    /// complex filters are applied client-side after SCAN results are returned.
    func buildFilteredQuery(
        namespace: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String = "and",
        limit: Int = 200
    ) -> String {
        // Check if any filter targets the Key column with a pattern-compatible operator
        let keyPattern = extractKeyPattern(from: filters, namespace: namespace)
        if let pattern = keyPattern {
            return "SCAN 0 MATCH \"\(pattern)\" COUNT \(limit)"
        }

        return buildBaseQuery(namespace: namespace, limit: limit)
    }

    /// Build a count command for a namespace.
    /// When a namespace filter is active, DBSIZE would overcount because it
    /// returns the total key count for the entire database. We use a SCAN-based
    /// approach instead; note the returned count is approximate since SCAN may
    /// return duplicates across iterations and new keys may appear mid-scan.
    func buildCountQuery(namespace: String) -> String {
        if namespace.isEmpty {
            return "DBSIZE"
        }
        return "SCAN 0 MATCH \"\(namespace)*\" COUNT 10000"
    }

    // MARK: - Private Helpers

    /// Try to extract a SCAN-compatible glob pattern from key-column filters
    private func extractKeyPattern(
        from filters: [(column: String, op: String, value: String)],
        namespace: String
    ) -> String? {
        let keyFilters = filters.filter { $0.column == "Key" }
        guard keyFilters.count == 1, let filter = keyFilters.first else { return nil }

        let prefix = namespace.isEmpty ? "" : namespace
        let value = escapeGlobChars(filter.value)

        switch filter.op {
        case "CONTAINS":
            return "\(prefix)*\(value)*"
        case "STARTS WITH":
            return "\(prefix)\(value)*"
        case "ENDS WITH":
            return "\(prefix)*\(value)"
        case "=":
            return "\(prefix)\(value)"
        default:
            return nil
        }
    }

    /// Escape Redis glob special characters in user input.
    /// Redis SCAN MATCH uses glob-style patterns where *, ?, and [ are special.
    private func escapeGlobChars(_ str: String) -> String {
        var result = ""
        for char in str {
            switch char {
            case "*", "?", "[", "]":
                result.append("\\")
                result.append(char)
            case "\\":
                result.append("\\\\")
            default:
                result.append(char)
            }
        }
        return result
    }
}
