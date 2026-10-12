//
//  SQLiteResultColumnsTests.swift
//  TableProTests
//
//  The first query on one connection after another connection altered the table named the old
//  columns, because they were read before the step that notices the schema changed.
//

import Foundation
import SQLite3
import Testing

struct SQLiteResultColumnsTests {
    private struct OpenFailed: Error {}

    private final class Database {
        let url: URL
        private(set) var handles: [OpaquePointer] = []

        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sqlite-result-columns-\(UUID().uuidString).sqlite")
        }

        func open() throws -> OpaquePointer {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
                throw OpenFailed()
            }
            handles.append(handle)
            return handle
        }

        func run(_ sql: String, on handle: OpaquePointer) {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }

        func close() {
            handles.forEach { sqlite3_close($0) }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func firstStep(of sql: String, on handle: OpaquePointer) -> SQLiteResultColumns.FirstStep? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return SQLiteResultColumns.stepFirst(statement)
    }

    @Test("A column another connection added is named on the first query that follows")
    func namesAColumnAddedOnAnotherConnection() throws {
        let database = Database()
        defer { database.close() }
        let session = try database.open()
        let pooled = try database.open()
        database.run("CREATE TABLE fixture (id INTEGER PRIMARY KEY, label TEXT)", on: session)
        database.run("INSERT INTO fixture VALUES (1, 'First')", on: session)
        #expect(firstStep(of: "SELECT * FROM fixture", on: session)?.names == ["id", "label"])

        database.run("ALTER TABLE fixture ADD COLUMN added_col TEXT", on: pooled)

        let step = try #require(firstStep(of: "SELECT * FROM fixture", on: session))
        #expect(step.result == SQLITE_ROW)
        #expect(step.names == ["id", "label", "added_col"])
        #expect(step.typeNames == ["INTEGER", "TEXT", "TEXT"])
        #expect(step.count == 3)
    }

    @Test("A query that returns no rows still names its columns")
    func namesTheColumnsOfAnEmptyResult() throws {
        let database = Database()
        defer { database.close() }
        let handle = try database.open()
        database.run("CREATE TABLE empty_fixture (id INTEGER PRIMARY KEY, label TEXT)", on: handle)

        let step = try #require(firstStep(of: "SELECT * FROM empty_fixture", on: handle))

        #expect(step.result == SQLITE_DONE)
        #expect(step.names == ["id", "label"])
    }
}
