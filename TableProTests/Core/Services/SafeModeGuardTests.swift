//
//  SafeModeGuardTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor @Suite("SafeModeGuard")
struct SafeModeGuardTests {
    // MARK: - Silent level

    @Test("Silent level allows read operations")
    func silentAllowsRead() async {
        let result = await SafeModeGuard.checkPermission(
            level: .silent, isWriteOperation: false,
            sql: "SELECT * FROM users", operationDescription: "Select",
            window: nil
        )
        if case .blocked = result {
            Issue.record("Expected .allowed but got .blocked")
        }
    }

    @Test("Silent level allows write operations")
    func silentAllowsWrite() async {
        let result = await SafeModeGuard.checkPermission(
            level: .silent, isWriteOperation: true,
            sql: "DROP TABLE users", operationDescription: "Drop table",
            window: nil
        )
        if case .blocked = result {
            Issue.record("Expected .allowed but got .blocked")
        }
    }

    // MARK: - Read-only level

    @Test("Read-only level allows read operations")
    func readOnlyAllowsRead() async {
        let result = await SafeModeGuard.checkPermission(
            level: .readOnly, isWriteOperation: false,
            sql: "SELECT 1", operationDescription: "Select",
            window: nil
        )
        if case .blocked = result {
            Issue.record("Expected .allowed but got .blocked")
        }
    }

    @Test("Read-only level blocks write operations")
    func readOnlyBlocksWrite() async {
        let result = await SafeModeGuard.checkPermission(
            level: .readOnly, isWriteOperation: true,
            sql: "DELETE FROM users", operationDescription: "Delete",
            window: nil
        )
        guard case let .blocked(message) = result else {
            Issue.record("Expected .blocked but got .allowed")
            return
        }
        #expect(message.contains("read-only"))
    }

    // MARK: - MongoDB / Redis special handling

    @Test("Read-only blocks MongoDB even when isWriteOperation is false")
    func readOnlyBlocksMongoDB() async {
        let result = await SafeModeGuard.checkPermission(
            level: .readOnly, isWriteOperation: false,
            sql: "db.users.find({})", operationDescription: "Find",
            window: nil, databaseType: .mongodb
        )
        guard case let .blocked(message) = result else {
            Issue.record("Expected .blocked for MongoDB but got .allowed")
            return
        }
        #expect(message.contains("read-only"))
    }

    @Test("Read-only blocks Redis even when isWriteOperation is false")
    func readOnlyBlocksRedis() async {
        let result = await SafeModeGuard.checkPermission(
            level: .readOnly, isWriteOperation: false,
            sql: "GET key", operationDescription: "Get",
            window: nil, databaseType: .redis
        )
        guard case let .blocked(message) = result else {
            Issue.record("Expected .blocked for Redis but got .allowed")
            return
        }
        #expect(message.contains("read-only"))
    }

    @Test("Silent level allows MongoDB regardless of write flag")
    func silentAllowsMongoDB() async {
        let result = await SafeModeGuard.checkPermission(
            level: .silent, isWriteOperation: false,
            sql: "db.users.find({})", operationDescription: "Find",
            window: nil, databaseType: .mongodb
        )
        if case .blocked = result {
            Issue.record("Expected .allowed for MongoDB in silent mode but got .blocked")
        }
    }

    @Test("Silent level allows Redis regardless of write flag")
    func silentAllowsRedis() async {
        let result = await SafeModeGuard.checkPermission(
            level: .silent, isWriteOperation: false,
            sql: "GET key", operationDescription: "Get",
            window: nil, databaseType: .redis
        )
        if case .blocked = result {
            Issue.record("Expected .allowed for Redis in silent mode but got .blocked")
        }
    }

    @Test("Read-only allows non-MongoDB/Redis read operations with databaseType set")
    func readOnlyAllowsMySQLRead() async {
        let result = await SafeModeGuard.checkPermission(
            level: .readOnly, isWriteOperation: false,
            sql: "SELECT * FROM users", operationDescription: "Select",
            window: nil, databaseType: .mysql
        )
        if case .blocked = result {
            Issue.record("Expected .allowed for MySQL read but got .blocked")
        }
    }
}
