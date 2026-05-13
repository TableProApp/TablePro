//
//  PostgreSQLSchemaFilterTests.swift
//  TableProTests
//
//  Tests for PostgreSQLSchemaQueries (compiled via symlink from
//  PostgreSQLDriverPlugin). Regression cover for the underscore-as-wildcard
//  bug in the `LIKE 'pg_%'` filter that silently excluded user schemas like
//  `pgboss`, `pgcrypto`, and `pgvector`.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.listSchemas")
struct PostgreSQLListSchemasTests {
    @Test("retains user schemas that start with 'pg'", arguments: [
        "pgboss", "pgcrypto", "pgvector", "pgaudit", "pgrouting"
    ])
    func retainsPgPrefixedUserSchemas(name: String) {
        #expect(!filterRejects(name, query: PostgreSQLSchemaQueries.listSchemas))
    }

    @Test("rejects built-in pg_* system schemas", arguments: [
        "pg_catalog", "pg_toast", "pg_temp_1", "pg_toast_temp_1"
    ])
    func rejectsSystemSchemas(name: String) {
        #expect(filterRejects(name, query: PostgreSQLSchemaQueries.listSchemas))
    }

    @Test("rejects information_schema")
    func rejectsInformationSchema() {
        #expect(filterRejects("information_schema", query: PostgreSQLSchemaQueries.listSchemas))
    }

    @Test("retains plain user schemas", arguments: [
        "public", "auth", "myapp", "analytics"
    ])
    func retainsPlainUserSchemas(name: String) {
        #expect(!filterRejects(name, query: PostgreSQLSchemaQueries.listSchemas))
    }
}

@Suite("PostgreSQLSchemaQueries.listSchemasRedshift")
struct RedshiftListSchemasTests {
    @Test("retains user schemas that start with 'pg'", arguments: [
        "pgboss", "pgcrypto", "pgvector"
    ])
    func retainsPgPrefixedUserSchemas(name: String) {
        #expect(!filterRejects(name, query: PostgreSQLSchemaQueries.listSchemasRedshift))
    }

    @Test("rejects built-in pg_* system schemas", arguments: [
        "pg_catalog", "pg_toast", "pg_internal"
    ])
    func rejectsSystemSchemas(name: String) {
        #expect(filterRejects(name, query: PostgreSQLSchemaQueries.listSchemasRedshift))
    }
}

private func filterRejects(_ name: String, query: String) -> Bool {
    if query.contains("'\(name)'") { return true }

    for (pattern, escape) in extractNotLikePatterns(query) where evaluateLike(pattern: pattern, escape: escape, value: name) {
        return true
    }
    return false
}

private func extractNotLikePatterns(_ sql: String) -> [(pattern: String, escape: Character?)] {
    let regex = #"NOT LIKE\s+'((?:[^'\\]|\\.)*)'(?:\s+ESCAPE\s+'(\\?.)')?"#
    guard let nsRegex = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else { return [] }

    let nsRange = NSRange(sql.startIndex..<sql.endIndex, in: sql)
    var results: [(String, Character?)] = []

    nsRegex.enumerateMatches(in: sql, options: [], range: nsRange) { match, _, _ in
        guard let match, let patternRange = Range(match.range(at: 1), in: sql) else { return }
        let rawPattern = String(sql[patternRange]).replacingOccurrences(of: "\\\\", with: "\\")

        var escape: Character?
        if match.numberOfRanges > 2, let escapeRange = Range(match.range(at: 2), in: sql) {
            let raw = String(sql[escapeRange]).replacingOccurrences(of: "\\\\", with: "\\")
            escape = raw.last
        }
        results.append((rawPattern, escape))
    }
    return results
}

private func evaluateLike(pattern: String, escape: Character?, value: String) -> Bool {
    var regex = "^"
    var iterator = pattern.makeIterator()
    while let ch = iterator.next() {
        if let escape, ch == escape, let next = iterator.next() {
            regex += NSRegularExpression.escapedPattern(for: String(next))
        } else if ch == "%" {
            regex += ".*"
        } else if ch == "_" {
            regex += "."
        } else {
            regex += NSRegularExpression.escapedPattern(for: String(ch))
        }
    }
    regex += "$"
    return value.range(of: regex, options: .regularExpression) != nil
}
