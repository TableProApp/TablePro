//
//  SQLiteSingleStatementTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import TableProSQLiteCore
import Testing

struct SQLiteSingleStatementTests {
    private func withDriver(_ body: (SQLitePluginDriver) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-single-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        try await body(driver)
    }

    @Test("A second statement in one text is refused, and nothing in it runs", arguments: [
        "SELECT 1; DROP TABLE kept",
        "SELECT 1; DELETE FROM kept",
        "SELECT 1; garbage",
    ])
    func secondStatementIsRefused(sql: String) async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "CREATE TABLE kept (a INT)")
            _ = try await driver.execute(query: "INSERT INTO kept VALUES (1)")

            await #expect(throws: (any Error).self) {
                _ = try await driver.executeUserQuery(query: sql, rowCap: nil, parameters: nil)
            }
            await #expect(throws: (any Error).self) {
                _ = try await driver.executeUserQuery(query: sql, rowCap: 10, parameters: nil)
            }
            let rows = try await driver.execute(query: "SELECT count(*) FROM kept").rows
            #expect(rows.first?.first?.asText == "1")
        }
    }

    @Test("A refused text is never prepared past its first statement, nor at all when a PRAGMA leads it", arguments: [
        "SELECT 1; PRAGMA foreign_keys = OFF", "PRAGMA foreign_keys = OFF; SELECT 1", "pragma foreign_keys=0;pragma x",
        "EXPLAIN PRAGMA foreign_keys = OFF; SELECT 1", "explain query plan pragma foreign_keys = OFF; SELECT 1",
    ])
    func refusedPragmaChangesNothing(sql: String) async throws {
        try await withDriver { driver in
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            await #expect(throws: (any Error).self) {
                _ = try await driver.executeUserQuery(query: sql, rowCap: nil, parameters: nil)
            }
            let rows = try await driver.execute(query: "PRAGMA foreign_keys").rows
            #expect(rows.first?.first?.asText == "1")
        }
    }

    @Test("A PRAGMA alone, or with only trivia after it, is one statement", arguments: [
        ("PRAGMA foreign_keys = OFF", false), ("PRAGMA foreign_keys = OFF; -- done", false),
        ("PRAGMA user_version = 3; SELECT 1", true), ("  /* c */ Pragma x; DROP TABLE t", true),
        ("PRAGMA_x; SELECT 1", false), ("SELECT 1; SELECT 2", false), ("PRAGMA table_info('a;b')", false),
        ("EXPLAIN PRAGMA x; SELECT 1", true), ("EXPLAIN QUERY PLAN PRAGMA x; SELECT 1", true),
        ("EXPLAIN SELECT 1; SELECT 2", false),
    ])
    func pragmaReading(sql: String, holdsSecond: Bool) {
        #expect(sql.withCString { SQLiteStatementTail.pragmaHoldsSecondStatement($0) } == holdsSecond)
    }

    @Test("Blanks, comments and semicolons are all a tail may hold", arguments: [
        ("", false), ("  \n\t", false), (";;", false), ("-- c", false), ("-- c\n;", false), ("/* c */", false),
        ("/* open", false), ("/**/ ;", false), (" x", true), ("-- c\nDROP TABLE t", true), ("/* c */ SELECT 1", true),
        ("/", true), ("-", true),
    ])
    func tailReading(tail: String, holdsStatement: Bool) {
        #expect(tail.withCString { SQLiteStatementTail.holdsStatement($0) } == holdsStatement)
    }

    @Test("A trailing terminator, blank or comment is not a second statement", arguments: [
        "SELECT 1;", "SELECT 1;  \n", "SELECT 1; -- done", "SELECT 1; /* done */", "SELECT 1 -- done",
    ])
    func trailingTriviaRuns(sql: String) async throws {
        try await withDriver { driver in
            let result = try await driver.executeUserQuery(query: sql, rowCap: nil, parameters: nil)
            #expect(result.rows.first?.first?.asText == "1")
        }
    }
}
