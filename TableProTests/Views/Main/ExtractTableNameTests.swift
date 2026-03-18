//
//  ExtractTableNameTests.swift
//  TableProTests
//
//  Tests for extractTableName(from:) — verifies SQL and MQL
//  query patterns including the MongoDB bracket notation fix.
//

import Foundation
import Testing

@testable import TablePro

@Suite("ExtractTableName")
@MainActor
struct ExtractTableNameTests {
    private func makeCoordinator() -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        return MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
    }

    // MARK: - SQL extraction

    @Test("SQL: SELECT * FROM users")
    func sqlSelectStar() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "SELECT * FROM users")
        #expect(result == "users")
    }

    @Test("SQL: SELECT with columns and WHERE clause")
    func sqlSelectWithWhere() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "SELECT id, name FROM orders WHERE id = 1")
        #expect(result == "orders")
    }

    @Test("SQL: extra whitespace and LIMIT")
    func sqlWhitespaceAndLimit() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "  SELECT * FROM  products  LIMIT 10")
        #expect(result == "products")
    }

    @Test("SQL: backtick-quoted table name")
    func sqlBacktickQuoted() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "SELECT * FROM `quoted_table` WHERE 1")
        #expect(result == "quoted_table")
    }

    // MARK: - MQL bracket notation (regression fix)

    @Test("MQL bracket: db[\"users\"].find()")
    func mqlBracketSimple() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "db[\"users\"].find()")
        #expect(result == "users")
    }

    @Test("MQL bracket: hyphenated collection name")
    func mqlBracketHyphenated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "db[\"my-collection\"].find({})")
        #expect(result == "my-collection")
    }

    @Test("MQL bracket: dotted collection name")
    func mqlBracketDotted() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "db[\"my.dotted.collection\"].find()")
        #expect(result == "my.dotted.collection")
    }

    @Test("MQL bracket: leading whitespace with aggregate")
    func mqlBracketLeadingWhitespace() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "  db[\"users\"].aggregate([])")
        #expect(result == "users")
    }

    // MARK: - MQL dot notation

    @Test("MQL dot: db.users.find()")
    func mqlDotSimple() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "db.users.find()")
        #expect(result == "users")
    }

    @Test("MQL dot: db.orders.aggregate([])")
    func mqlDotAggregate() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "db.orders.aggregate([])")
        #expect(result == "orders")
    }

    @Test("MQL dot: leading whitespace")
    func mqlDotLeadingWhitespace() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "  db.products.find({})")
        #expect(result == "products")
    }

    // MARK: - Edge cases

    @Test("Empty string returns nil")
    func emptyString() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "")
        #expect(result == nil)
    }

    @Test("Random text returns nil")
    func randomText() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "hello world this is not a query")
        #expect(result == nil)
    }

    @Test("Non-SELECT SQL returns nil")
    func nonSelectSql() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let result = coordinator.extractTableName(from: "INSERT INTO users VALUES (1)")
        #expect(result == nil)
    }
}
