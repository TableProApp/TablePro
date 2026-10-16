//
//  ClickHouseMetadataScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// The export tree reads tables of other databases over one session, so every metadata read names
/// the database it was asked about. Measured on 23.8.8.20 before this: `SHOW CREATE TABLE events`
/// on a session in `va` answered for `va.events` when the caller asked about `vb.events`.
struct ClickHouseMetadataScopeTests {
    @Test("Column, index, row count, metadata and DDL reads name the database asked about")
    func readsNameTheDatabase() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        _ = try await driver.fetchColumns(table: "events", schema: "vb")
        _ = try await driver.fetchAllColumns(schema: "vb")
        _ = try await driver.fetchIndexes(table: "events", schema: "vb")
        _ = try await driver.fetchApproximateRowCount(table: "events", schema: "vb")
        _ = try await driver.fetchTableMetadata(table: "events", schema: "vb")
        _ = try await driver.fetchTableDDL(table: "events", schema: "vb")

        let bodies = server.requests.map(\.body)
        #expect(!bodies.contains { $0.contains("currentDatabase()") })
        #expect(bodies.filter { $0.contains("database = 'vb'") }.count == bodies.count - 1)
        #expect(bodies.contains("SHOW CREATE TABLE `vb`.`events`"))
    }

    @Test("No database named reads the session's")
    func noDatabaseReadsTheSession() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        _ = try await driver.fetchColumns(table: "events", schema: nil)
        _ = try await driver.fetchTableDDL(table: "events", schema: nil)

        let bodies = server.requests.map(\.body)
        #expect(bodies.filter { $0.contains("database = currentDatabase()") }.count == 2)
        #expect(bodies.contains("SHOW CREATE TABLE `events`"))
    }

    @Test("A backslash and a quote in a table name cannot end the literal early")
    func tableNameIsEscaped() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        _ = try await driver.fetchColumns(table: #"a\'b"#, schema: nil)

        #expect(server.requests.allSatisfy { $0.body.contains(#"= 'a\\''b'"#) })
    }

    @Test("All-tables metadata names the database asked about")
    func allTablesMetadataNamesTheDatabase() {
        let driver = ClickHouseStubServer().connectedDriver()
        #expect(driver.allTablesMetadataSQL(schema: "vb")?.contains("WHERE database = 'vb'") == true)
    }

    @Test("A server without the data-skipping table reads only the sorting key")
    func noDataSkippingTable() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = .testing(catalog: [])

        _ = try await driver.fetchIndexes(table: "events", schema: nil)

        #expect(server.requests.count == 1)
        #expect(!server.requests.contains { $0.body.contains("data_skipping_indices") })
    }

    @Test("A server without system.tables.comment is not asked for it")
    func noTableCommentColumn() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = .testing(catalog: [])

        _ = try await driver.fetchTableMetadata(table: "events", schema: nil)

        #expect(!server.requests.contains { $0.body.contains("comment") })
        #expect(driver.allTablesMetadataSQL(schema: nil)?.contains("'' as comment") == true)
    }

    /// 21.8 answers with a qualified name and a column list, the shape a materialized view
    /// already gets.
    @Test("A server without as_select answers a view definition with SHOW CREATE TABLE")
    func noAsSelectColumn() async throws {
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: "statement\nString\nCREATE VIEW default.v AS SELECT 1\n")
        }
        let driver = server.connectedDriver()
        driver.serverProfile = .testing(catalog: [])

        let definition = try await driver.fetchViewDefinition(view: "v", schema: nil)

        #expect(definition == "CREATE VIEW default.v AS SELECT 1")
        #expect(server.requests.map(\.body) == ["SHOW CREATE TABLE `v`"])
    }

    @Test("A server without system.functions.create_query lists no functions and is not asked")
    func noFunctionCatalog() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = .testing(catalog: [.tablesComment])

        #expect(try await driver.fetchRoutines(schema: nil).isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test("21.10 has create_query but no origin, so its SQL functions are listed by create_query")
    func functionsWithoutOrigin() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = .testing(catalog: [.functionsCreateQuery])

        _ = try await driver.fetchRoutines(schema: nil)

        #expect(server.requests.map(\.body) == [ClickHouseObjectQueries.functionListWithoutOrigin])
    }

    /// `SHOW CREATE FUNCTION` answered `Code: 62 SYNTAX_ERROR` on 21.3, 21.8, 23.8.8 and 25.8.33.
    @Test("A function with no definition is read from create_query and reported as not found")
    func executableFunctionHasNoSource() async throws {
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: "create_query\nString\n\n")
        }
        let driver = server.connectedDriver()
        let routine = PluginRoutineInfo(
            name: "exec_fn",
            kind: .function,
            schema: nil,
            returnType: nil,
            language: "SQL",
            argumentSignature: nil,
            identity: nil,
            definition: "",
            attributes: []
        )

        await #expect(throws: PluginObjectSourceError.self) { try await driver.fetchRoutineDDL(routine) }
        #expect(server.requests.map(\.body) == ["SELECT create_query FROM system.functions WHERE name = 'exec_fn'"])
    }
}
