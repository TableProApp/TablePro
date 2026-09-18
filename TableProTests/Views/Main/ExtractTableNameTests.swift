//
//  ExtractTableNameTests.swift
//  TableProTests
//
//  Tests for extractTableName(from:) — verifies SQL and MQL
//  query patterns including the MongoDB bracket notation fix.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ExtractTableName")
@MainActor
struct ExtractTableNameTests {
    private func makeCoordinator(type: DatabaseType = .mysql) -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection(database: "db_a", type: type)
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        return MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
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

    // MARK: - Table editability (#2150)

    @Test("SQL: a table alias resolves to the table")
    func sqlTableAlias() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        #expect(coordinator.extractTableName(from: "select * from users u WHERE u.id = 1;") == "users")
        #expect(coordinator.extractTableName(from: "SELECT * FROM users AS u WHERE u.id = 1") == "users")
    }

    @Test("A query tab whose SELECT uses a table alias is editable")
    func aliasedQueryTabIsEditable() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let sql = "select * from users u WHERE u.id = 1"
        let tab = QueryTab(query: sql, tabType: .query)
        let resolved = coordinator.resolveTableEditability(tab: tab, sql: sql)

        #expect(resolved.tableName == "users")
        #expect(resolved.isEditable)
    }

    @Test("A query tab reading from more than one table stays read-only")
    func multiSourceQueryTabIsNotEditable() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let joinSQL = "SELECT * FROM users u JOIN orders o ON o.user_id = u.id"
        let joined = coordinator.resolveTableEditability(tab: QueryTab(query: joinSQL, tabType: .query), sql: joinSQL)
        #expect(joined.tableName == nil)
        #expect(!joined.isEditable)

        let unionSQL = "SELECT * FROM users u WHERE u.id > 0 UNION SELECT * FROM admins a WHERE a.id > 0"
        let unioned = coordinator.resolveTableEditability(tab: QueryTab(query: unionSQL, tabType: .query), sql: unionSQL)
        #expect(unioned.tableName == nil)
        #expect(!unioned.isEditable)
    }

    @Test("PostgreSQL jsonb path operators are not read as comments")
    func postgresJsonbOperatorsResolve() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        #expect(coordinator.extractTableName(from: "SELECT data #>> '{name}' FROM users WHERE id = 1") == "users")
    }

    @Test("A MySQL hash comment does not hide the table")
    func mysqlHashCommentIsTrivia() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        #expect(coordinator.extractTableName(from: "SELECT * # FROM evil\nFROM users") == "users")
    }
}
