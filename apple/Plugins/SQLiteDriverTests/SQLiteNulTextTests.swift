//
//  SQLiteNulTextTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

/// SQLite stores text with a NUL inside it. Reading such text as a C string, or binding it with no length, cut it at
/// the NUL, so an edit by a key holding one matched another row or none.
struct SQLiteNulTextTests {
    private static let key = "k\u{0}1"
    private static let value = "a\u{0}b"

    private func connectedDriver() async throws -> (SQLitePluginDriver, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-nul-\(UUID().uuidString).sqlite")
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT)")
        return (driver, url)
    }

    private func texts(_ rows: [PluginRow]) -> [[String?]] {
        rows.map { row in row.map { $0.asText } }
    }

    @Test("Text with a NUL reads back whole after a bound insert")
    func boundInsertReadsWhole() async throws {
        let (driver, url) = try await connectedDriver()
        defer {
            driver.disconnect()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await driver.executeParameterized(
            query: "INSERT INTO notes VALUES (?, ?)", parameters: [.text(Self.key), .text(Self.value)]
        )

        let read = try await driver.execute(query: "SELECT id, body, hex(body) FROM notes")
        #expect(texts(read.rows) == [[Self.key, Self.value, "610062"]])
    }

    @Test("Text with a NUL streams whole")
    func streamsWhole() async throws {
        let (driver, url) = try await connectedDriver()
        defer {
            driver.disconnect()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await driver.execute(query: "INSERT INTO notes VALUES ('k' || char(0) || '1', 'a' || char(0) || 'b')")

        var rows: [PluginRow] = []
        for try await element in driver.streamRows(query: "SELECT id, body FROM notes") {
            if case .rows(let batch) = element { rows.append(contentsOf: batch) }
        }
        #expect(texts(rows) == [[Self.key, Self.value]])
    }

    @Test("An edit by a key holding a NUL changes that row, not the one its cut key names")
    func editByKeyWithNul() async throws {
        let (driver, url) = try await connectedDriver()
        defer {
            driver.disconnect()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await driver.executeParameterized(
            query: "INSERT INTO notes VALUES (?, ?), ('k', 'other')", parameters: [.text(Self.key), .text(Self.value)]
        )
        let keys = try await driver.execute(query: "SELECT id FROM notes WHERE body <> 'other'")
        let readKey = try #require(keys.rows.first?.first?.asText)

        let update = try await driver.executeParameterized(
            query: "UPDATE notes SET body = ? WHERE id = ?", parameters: [.text("x\u{0}y"), .text(readKey)]
        )
        #expect(update.rowsAffected == 1)

        let after = try await driver.execute(query: "SELECT id, body FROM notes ORDER BY id")
        #expect(texts(after.rows) == [["k", "other"], [Self.key, "x\u{0}y"]])
    }
}
