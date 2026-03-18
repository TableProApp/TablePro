//
//  TableOperationsPluginTests.swift
//  TableProTests
//
//  Tests for plugin-first table operation SQL generation in
//  MainContentCoordinator+TableOperations.
//

import Foundation
import Testing

@testable import TablePro

@Suite("TableOperations Plugin Fallback")
@MainActor
struct TableOperationsPluginTests {
    // When no plugin driver is connected, the coordinator falls back
    // to built-in DatabaseType switches. These tests verify that fallback.

    private func makeCoordinator(type: DatabaseType = .mysql) -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection(database: "testdb", type: type)
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

    // MARK: - FK Disable Fallback (no plugin)

    @Test("FK disable: MySQL returns SET FOREIGN_KEY_CHECKS=0")
    func fkDisableMySQL() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkDisableStatements(for: .mysql)
        #expect(stmts == ["SET FOREIGN_KEY_CHECKS=0"])
    }

    @Test("FK disable: MariaDB returns SET FOREIGN_KEY_CHECKS=0")
    func fkDisableMariaDB() {
        let coordinator = makeCoordinator(type: .mariadb)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkDisableStatements(for: .mariadb)
        #expect(stmts == ["SET FOREIGN_KEY_CHECKS=0"])
    }

    @Test("FK disable: SQLite returns PRAGMA foreign_keys = OFF")
    func fkDisableSQLite() {
        let coordinator = makeCoordinator(type: .sqlite)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkDisableStatements(for: .sqlite)
        #expect(stmts == ["PRAGMA foreign_keys = OFF"])
    }

    @Test("FK disable: PostgreSQL returns empty")
    func fkDisablePostgreSQL() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkDisableStatements(for: .postgresql)
        #expect(stmts.isEmpty)
    }

    // MARK: - FK Enable Fallback (no plugin)

    @Test("FK enable: MySQL returns SET FOREIGN_KEY_CHECKS=1")
    func fkEnableMySQL() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkEnableStatements(for: .mysql)
        #expect(stmts == ["SET FOREIGN_KEY_CHECKS=1"])
    }

    @Test("FK enable: SQLite returns PRAGMA foreign_keys = ON")
    func fkEnableSQLite() {
        let coordinator = makeCoordinator(type: .sqlite)
        defer { coordinator.teardown() }

        let stmts = coordinator.fkEnableStatements(for: .sqlite)
        #expect(stmts == ["PRAGMA foreign_keys = ON"])
    }

    // MARK: - Truncate Fallback (no plugin)

    @Test("Truncate: MySQL uses TRUNCATE TABLE with backtick-quoted name")
    func truncateMySQL() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["users"],
            deletes: [],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE `users`"])
    }

    @Test("Truncate: PostgreSQL with cascade")
    func truncatePostgreSQLCascade() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["orders"],
            deletes: [],
            options: ["orders": TableOperationOptions(ignoreForeignKeys: false, cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE \"orders\" CASCADE"])
    }

    @Test("Truncate: PostgreSQL without cascade")
    func truncatePostgreSQLNoCascade() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["orders"],
            deletes: [],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE \"orders\""])
    }

    // MARK: - Drop Fallback (no plugin)

    @Test("Drop: MySQL uses DROP TABLE with backtick-quoted name")
    func dropMySQL() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: [],
            deletes: ["users"],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE `users`"])
    }

    @Test("Drop: PostgreSQL with cascade")
    func dropPostgreSQLCascade() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: [],
            deletes: ["orders"],
            options: ["orders": TableOperationOptions(ignoreForeignKeys: false, cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE \"orders\" CASCADE"])
    }

    // MARK: - Combined Operations

    @Test("MySQL: truncate + drop with FK handling")
    func combinedMySQLWithFK() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["alpha"],
            deletes: ["beta"],
            options: [
                "alpha": TableOperationOptions(ignoreForeignKeys: true, cascade: false),
                "beta": TableOperationOptions(ignoreForeignKeys: true, cascade: false)
            ],
            includeFKHandling: true
        )
        // FK disable, truncate alpha, drop beta, FK enable
        #expect(stmts.first == "SET FOREIGN_KEY_CHECKS=0")
        #expect(stmts.last == "SET FOREIGN_KEY_CHECKS=1")
        #expect(stmts.contains("TRUNCATE TABLE `alpha`"))
        #expect(stmts.contains("DROP TABLE `beta`"))
    }

    @Test("Tables are sorted for consistent execution order")
    func sortedOrder() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["zebra", "apple"],
            deletes: [],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE `apple`", "TRUNCATE TABLE `zebra`"])
    }
}
