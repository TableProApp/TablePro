//
//  SQLiteTypelessColumnTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

/// SQLite reads `body` in `CREATE TABLE notes (tag TEXT, body)` with an empty type, and a structure save on such a
/// table used to be refused. The driver's half: the drop it is handed runs, whichever column goes.
struct SQLiteTypelessColumnTests {
    @Test("A column drops from a table that holds a typeless column", arguments: ["tag", "body"])
    func dropBesideATypelessColumn(column: String) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-typeless-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE TABLE notes (tag TEXT, body)")
        _ = try await driver.execute(query: "INSERT INTO notes VALUES ('a', 1)")
        let before = try await driver.fetchColumns(table: "notes", schema: nil)
        try #require(before.map(\.name) == ["tag", "body"])
        #expect(before[1].dataType.isEmpty, "body is declared without a type")

        let drop = try #require(driver.generateDropColumnSQL(table: "notes", columnName: column))
        _ = try await driver.execute(query: drop)

        let after = try await driver.fetchColumns(table: "notes", schema: nil)
        #expect(after.map(\.name) == ["tag", "body"].filter { $0 != column })
        let count = try await driver.execute(query: "SELECT count(*) FROM notes")
        #expect(count.rows.first?.first?.asText == "1", "The row stays")
    }
}
