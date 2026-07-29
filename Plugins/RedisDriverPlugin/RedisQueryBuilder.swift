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

    /// Build a key-browse command for a namespace. KEYBROWSE iterates the SCAN cursor
    /// to completion (bounded) and honors LIMIT/OFFSET, so paging returns every key.
    func buildBaseQuery(
        namespace: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let pattern = namespace.isEmpty ? nil : "\(namespace)*"
        return buildKeyBrowseQuery(pattern: pattern, typeScope: nil, limit: limit, offset: offset)
    }

    /// Build a key-browse command from filter tuples.
    /// A ("Key", "MATCH", glob) tuple is a raw glob typed by the user and passed verbatim.
    /// A ("Type", "=", type) tuple selects a server-side SCAN TYPE scope.
    /// Legacy Key operators (CONTAINS, STARTS WITH, ...) still resolve to an escaped glob.
    func buildFilteredQuery(
        namespace: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String = "and",
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let pattern = extractBrowsePattern(from: filters, namespace: namespace)
        let typeScope = extractTypeScope(from: filters)

        guard pattern != nil || typeScope != nil else {
            return buildBaseQuery(namespace: namespace, limit: limit, offset: offset)
        }

        return buildKeyBrowseQuery(pattern: pattern, typeScope: typeScope, limit: limit, offset: offset)
    }

    func buildKeyBrowseQuery(pattern: String?, typeScope: String?, limit: Int, offset: Int) -> String {
        var command = "KEYBROWSE"
        if let pattern, !pattern.isEmpty {
            command += " MATCH \"\(quoteForCommand(pattern))\""
        }
        if let typeScope, !typeScope.isEmpty {
            command += " TYPE \(typeScope)"
        }
        command += " LIMIT \(limit) OFFSET \(offset)"
        return command
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

    /// Resolve the SCAN MATCH glob from key-column filters.
    /// A MATCH op carries a raw glob the user typed; legacy operators build an escaped glob.
    private func extractBrowsePattern(
        from filters: [(column: String, op: String, value: String)],
        namespace: String
    ) -> String? {
        let keyFilters = filters.filter { $0.column == "Key" }
        guard keyFilters.count == 1, let filter = keyFilters.first else { return nil }

        let prefix = namespace.isEmpty ? "" : namespace

        if filter.op == "MATCH" {
            return prefix.isEmpty ? filter.value : "\(prefix)\(filter.value)"
        }
        return extractKeyPattern(from: filters, namespace: namespace)
    }

    private func extractTypeScope(
        from filters: [(column: String, op: String, value: String)]
    ) -> String? {
        let typeFilters = filters.filter { $0.column == "Type" && $0.op == "=" }
        guard typeFilters.count == 1, let filter = typeFilters.first, !filter.value.isEmpty else { return nil }
        return filter.value.lowercased()
    }

    private func quoteForCommand(_ str: String) -> String {
        var result = ""
        for char in str {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.append(char)
            }
        }
        return result
    }

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
