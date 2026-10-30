//
//  SQLiteSessionScopeTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteSessionScopeTests {
    private func withDriver(_ body: (SQLitePluginDriver) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-scope-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        try await body(driver)
    }

    private func foreignKeys(_ driver: SQLitePluginDriver) async throws -> String? {
        try await driver.execute(query: "PRAGMA foreign_keys").rows.first?.first?.asText
    }

    @Test("Closing a preserve scope turns foreign keys back off after the statements inside turned them on")
    func preserveRestoresForeignKeys() async throws {
        try await withDriver { driver in
            #expect(try await foreignKeys(driver) == "0")
            let scope = try #require(try await driver.openSessionScope(for: .preserve))
            #expect(scope.applied.isEmpty)
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            try await driver.closeSessionScope(scope)
            #expect(try await foreignKeys(driver) == "0")
        }
    }

    @Test("A preserve scope that cannot put foreign keys back inside a transaction says so")
    func preserveCloseInsideTransactionThrows() async throws {
        try await withDriver { driver in
            let scope = try #require(try await driver.openSessionScope(for: .preserve))
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            _ = try await driver.execute(query: "BEGIN")
            await #expect(throws: (any Error).self) { try await driver.closeSessionScope(scope) }
            _ = try await driver.execute(query: "ROLLBACK")
            try await driver.closeSessionScope(scope)
            #expect(try await foreignKeys(driver) == "0")
        }
    }

    @Test("Relaxing turns foreign keys off for the writes and closing turns them back on")
    func relaxTurnsForeignKeysOffAndBack() async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "CREATE TABLE parent (id INTEGER PRIMARY KEY)")
            _ = try await driver.execute(query: "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id))")
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            let scope = try #require(try await driver.openSessionScope(for: .relaxedForeignKeys))
            #expect(scope.applied == [PluginSessionSetting(name: "foreign_keys", value: "0")])
            #expect(try await foreignKeys(driver) == "0")
            _ = try await driver.execute(query: "INSERT INTO child VALUES (1, 7)")
            try await driver.closeSessionScope(scope)
            #expect(try await foreignKeys(driver) == "1")
        }
    }

    /// sqlite.org/pragma.html#pragma_foreign_keys: the pragma is a no-op while a transaction is open.
    @Test("Relaxing inside a transaction opens no scope and leaves foreign keys on")
    func relaxInsideTransactionIsNil() async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            _ = try await driver.execute(query: "BEGIN")
            #expect(try await driver.openSessionScope(for: .relaxedForeignKeys) == nil)
            #expect(try await foreignKeys(driver) == "1")
            _ = try await driver.execute(query: "ROLLBACK")
        }
    }

    @Test("Relaxing a connection whose foreign keys are already off opens no scope")
    func relaxWhenAlreadyOffIsNil() async throws {
        try await withDriver { driver in
            let scope = try await driver.openSessionScope(for: .relaxedForeignKeys)
            let value = try await foreignKeys(driver)
            #expect(scope == nil)
            #expect(value == "0")
        }
    }

    @Test("The verbatim purposes open no scope", arguments: [PluginSessionPurpose.verbatimRead, .verbatimWrite])
    func verbatimPurposesAreNil(_ purpose: PluginSessionPurpose) async throws {
        try await withDriver { driver in
            let scope = try await driver.openSessionScope(for: purpose)
            #expect(scope == nil)
        }
    }
}
