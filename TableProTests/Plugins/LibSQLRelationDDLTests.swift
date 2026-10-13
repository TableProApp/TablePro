//
//  LibSQLRelationDDLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private struct LibSQLRelationDDLRuntime: LibSQLLocalDatabaseRuntime {
    func prepareDatabase(_: OpaquePointer, loading _: [LoadableExtension]) throws {}

    func stepFirst(_ statement: OpaquePointer?) -> LibSQLLocalFirstStep {
        let firstStep = SQLiteResultColumns.stepFirst(statement)
        return LibSQLLocalFirstStep(result: firstStep.result, names: firstStep.names, typeNames: firstStep.typeNames)
    }
}

/// SQLite, libSQL and D1 read a relation's DDL from `sqlite_master` the same way, and libSQL's is the
/// one that runs against a real file here. A view used to fail with "Failed to fetch DDL for table",
/// which Show DDL and Copy DDL showed for every view.
struct LibSQLRelationDDLTests {
    private func withDriver(_ body: (LibSQLPluginDriver) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsql-relation-ddl-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = LibSQLPluginDriver(
            config: DriverConnectionConfig(
                host: "",
                port: 0,
                username: "",
                password: "",
                database: "",
                additionalFields: ["libsqlMode": "local", "libsqlFilePath": url.path]
            ),
            localDatabaseRuntime: LibSQLRelationDDLRuntime()
        )
        try await driver.connect()
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute(
            query: "CREATE VIEW named_item AS SELECT id, name FROM item WHERE name IS NOT NULL -- kept"
        )
        try await body(driver)
    }

    /// SQLite stores the trailing comment, so nothing is appended after it.
    @Test("A view answers with its own CREATE VIEW, exactly as written")
    func viewAnswersWithItsDefinition() async throws {
        try await withDriver { driver in
            let ddl = try await driver.fetchTableDDL(table: "named_item", schema: nil)
            #expect(ddl == "CREATE VIEW named_item AS SELECT id, name FROM item WHERE name IS NOT NULL -- kept")
        }
    }

    @Test("A table still answers with its CREATE TABLE")
    func tableStillAnswersWithItsTable() async throws {
        try await withDriver { driver in
            let ddl = try await driver.fetchTableDDL(table: "item", schema: nil)
            #expect(ddl.hasPrefix("CREATE TABLE"))
            #expect(!ddl.contains("CREATE VIEW"))
        }
    }

    @Test("A name that is neither still fails")
    func missingRelationStillFails() async throws {
        try await withDriver { driver in
            await #expect(throws: LibSQLError.self) {
                _ = try await driver.fetchTableDDL(table: "absent", schema: nil)
            }
        }
    }
}
