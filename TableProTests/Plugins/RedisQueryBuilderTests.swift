//
//  RedisQueryBuilderTests.swift
//  TableProTests
//
//  Tests for RedisQueryBuilder (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

@Suite("Redis Query Builder")
struct RedisQueryBuilderTests {
    private let builder = RedisQueryBuilder()

    // MARK: - Base Query

    @Test("Empty namespace produces wildcard SCAN")
    func emptyNamespaceWildcard() {
        let query = builder.buildBaseQuery(namespace: "")
        #expect(query == "SCAN 0 MATCH \"*\" COUNT 200")
    }

    @Test("Namespace appends wildcard")
    func namespaceAppendsWildcard() {
        let query = builder.buildBaseQuery(namespace: "cache:")
        #expect(query == "SCAN 0 MATCH \"cache:*\" COUNT 200")
    }

    @Test("Custom limit")
    func customLimit() {
        let query = builder.buildBaseQuery(namespace: "user:", limit: 500)
        #expect(query == "SCAN 0 MATCH \"user:*\" COUNT 500")
    }

    @Test("Sort columns and offset are accepted but do not change SCAN command")
    func sortAndOffsetIgnored() {
        let query = builder.buildBaseQuery(
            namespace: "test:",
            sortColumns: [(columnIndex: 0, ascending: true)],
            columns: ["Key"],
            limit: 100,
            offset: 50
        )
        #expect(query == "SCAN 0 MATCH \"test:*\" COUNT 100")
    }

    // MARK: - Filtered Query

    @Test("Contains filter on Key column")
    func containsFilterOnKey() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "session")]
        )
        #expect(query == "SCAN 0 MATCH \"*session*\" COUNT 200")
    }

    @Test("Contains filter with namespace prefix")
    func containsFilterWithNamespace() {
        let query = builder.buildFilteredQuery(
            namespace: "app:",
            filters: [(column: "Key", op: "CONTAINS", value: "user")]
        )
        #expect(query == "SCAN 0 MATCH \"app:*user*\" COUNT 200")
    }

    @Test("StartsWith filter on Key column")
    func startsWithFilterOnKey() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "STARTS WITH", value: "user")]
        )
        #expect(query == "SCAN 0 MATCH \"user*\" COUNT 200")
    }

    @Test("EndsWith filter on Key column")
    func endsWithFilterOnKey() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "ENDS WITH", value: ":data")]
        )
        #expect(query == "SCAN 0 MATCH \"*:data\" COUNT 200")
    }

    @Test("Equals filter on Key column")
    func equalsFilterOnKey() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "=", value: "mykey")]
        )
        #expect(query == "SCAN 0 MATCH \"mykey\" COUNT 200")
    }

    @Test("Equals filter with namespace")
    func equalsFilterWithNamespace() {
        let query = builder.buildFilteredQuery(
            namespace: "ns:",
            filters: [(column: "Key", op: "=", value: "mykey")]
        )
        #expect(query == "SCAN 0 MATCH \"ns:mykey\" COUNT 200")
    }

    @Test("Non-Key column filter falls back to base query")
    func nonKeyColumnFallsBack() {
        let query = builder.buildFilteredQuery(
            namespace: "test:",
            filters: [(column: "Value", op: "CONTAINS", value: "hello")]
        )
        #expect(query == "SCAN 0 MATCH \"test:*\" COUNT 200")
    }

    @Test("Multiple filters fall back to base query (only single Key filter supported)")
    func multipleFiltersFallBack() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [
                (column: "Key", op: "CONTAINS", value: "a"),
                (column: "Key", op: "CONTAINS", value: "b")
            ]
        )
        #expect(query == "SCAN 0 MATCH \"*\" COUNT 200")
    }

    @Test("Unsupported operator on Key falls back to base query")
    func unsupportedOperatorFallsBack() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "IS NULL", value: "")]
        )
        #expect(query == "SCAN 0 MATCH \"*\" COUNT 200")
    }

    @Test("Custom limit in filtered query")
    func filteredQueryCustomLimit() {
        let query = builder.buildFilteredQuery(
            namespace: "data:",
            filters: [(column: "Key", op: "CONTAINS", value: "test")],
            limit: 1000
        )
        #expect(query == "SCAN 0 MATCH \"data:*test*\" COUNT 1000")
    }

    @Test("Glob special characters are escaped in filter value")
    func globCharsEscaped() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "user*data")]
        )
        #expect(query == "SCAN 0 MATCH \"*user\\*data*\" COUNT 200")
    }

    @Test("Glob question mark is escaped")
    func globQuestionMarkEscaped() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "item?")]
        )
        #expect(query == "SCAN 0 MATCH \"*item\\?*\" COUNT 200")
    }

    @Test("Glob bracket is escaped")
    func globBracketEscaped() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "[test]")]
        )
        #expect(query == "SCAN 0 MATCH \"*\\[test\\]*\" COUNT 200")
    }

    @Test("Backslash is escaped")
    func backslashEscaped() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "path\\to")]
        )
        #expect(query == "SCAN 0 MATCH \"*path\\\\to*\" COUNT 200")
    }

    // MARK: - Count Query

    @Test("Count with empty namespace uses DBSIZE")
    func countEmptyNamespace() {
        let query = builder.buildCountQuery(namespace: "")
        #expect(query == "DBSIZE")
    }

    @Test("Count with namespace uses SCAN")
    func countWithNamespace() {
        let query = builder.buildCountQuery(namespace: "cache:")
        #expect(query == "SCAN 0 MATCH \"cache:*\" COUNT 10000")
    }
}
