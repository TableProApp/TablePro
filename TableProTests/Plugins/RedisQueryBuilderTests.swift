//
//  RedisQueryBuilderTests.swift
//  TableProTests
//
//  Tests for RedisQueryBuilder (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Redis Query Builder")
struct RedisQueryBuilderTests {
    private let builder = RedisQueryBuilder()

    // MARK: - Base Query

    @Test("Empty namespace produces a bare key-browse command")
    func emptyNamespaceWildcard() {
        let query = builder.buildBaseQuery(namespace: "")
        #expect(query == "KEYBROWSE LIMIT 200 OFFSET 0")
    }

    @Test("Namespace appends wildcard to the MATCH pattern")
    func namespaceAppendsWildcard() {
        let query = builder.buildBaseQuery(namespace: "cache:")
        #expect(query == "KEYBROWSE MATCH \"cache:*\" LIMIT 200 OFFSET 0")
    }

    @Test("Custom limit")
    func customLimit() {
        let query = builder.buildBaseQuery(namespace: "user:", limit: 500)
        #expect(query == "KEYBROWSE MATCH \"user:*\" LIMIT 500 OFFSET 0")
    }

    @Test("Offset pages through the namespace")
    func offsetPagesThrough() {
        let query = builder.buildBaseQuery(
            namespace: "test:",
            sortColumns: [(columnIndex: 0, ascending: true)],
            columns: ["Key"],
            limit: 100,
            offset: 50
        )
        #expect(query == "KEYBROWSE MATCH \"test:*\" LIMIT 100 OFFSET 50")
    }

    // MARK: - Key Browse Query

    @Test("Raw glob pattern is passed verbatim to MATCH")
    func rawGlobPatternVerbatim() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "MATCH", value: "user:*")]
        )
        #expect(query == "KEYBROWSE MATCH \"user:*\" LIMIT 200 OFFSET 0")
    }

    @Test("Type scope maps to a server-side TYPE clause")
    func typeScopeMapsToType() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Type", op: "=", value: "STRING")]
        )
        #expect(query == "KEYBROWSE TYPE string LIMIT 200 OFFSET 0")
    }

    @Test("Pattern and type scope combine into one KEYBROWSE command")
    func patternAndTypeCombine() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [
                (column: "Key", op: "MATCH", value: "session:*"),
                (column: "Type", op: "=", value: "hash")
            ]
        )
        #expect(query == "KEYBROWSE MATCH \"session:*\" TYPE hash LIMIT 200 OFFSET 0")
    }

    @Test("Page limit and offset pass through to the command")
    func limitAndOffsetPassThrough() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "MATCH", value: "user:*")],
            limit: 50,
            offset: 100
        )
        #expect(query == "KEYBROWSE MATCH \"user:*\" LIMIT 50 OFFSET 100")
    }

    @Test("Quotes and backslashes in a pattern are escaped for the command string")
    func patternQuotingEscaped() {
        let query = builder.buildKeyBrowseQuery(pattern: "a\"b\\c", typeScope: nil, limit: 200, offset: 0)
        #expect(query == "KEYBROWSE MATCH \"a\\\"b\\\\c\" LIMIT 200 OFFSET 0")
    }

    @Test("Empty pattern with no type scope produces a bare browse command")
    func emptyPatternNoScope() {
        let query = builder.buildKeyBrowseQuery(pattern: "", typeScope: nil, limit: 200, offset: 0)
        #expect(query == "KEYBROWSE LIMIT 200 OFFSET 0")
    }

    @Test("Legacy Contains operator resolves to an escaped glob KEYBROWSE")
    func legacyContainsResolvesToKeyBrowse() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [(column: "Key", op: "CONTAINS", value: "session")]
        )
        #expect(query == "KEYBROWSE MATCH \"*session*\" LIMIT 200 OFFSET 0")
    }

    @Test("Non-Key, non-Type filter falls back to the base browse command")
    func nonKeyColumnFallsBack() {
        let query = builder.buildFilteredQuery(
            namespace: "test:",
            filters: [(column: "Value", op: "CONTAINS", value: "hello")]
        )
        #expect(query == "KEYBROWSE MATCH \"test:*\" LIMIT 200 OFFSET 0")
    }

    @Test("Multiple Key filters fall back to the base browse command")
    func multipleKeyFiltersFallBack() {
        let query = builder.buildFilteredQuery(
            namespace: "",
            filters: [
                (column: "Key", op: "MATCH", value: "a*"),
                (column: "Key", op: "MATCH", value: "b*")
            ]
        )
        #expect(query == "KEYBROWSE LIMIT 200 OFFSET 0")
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
