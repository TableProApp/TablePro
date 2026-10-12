//
//  PluginDriverAdapterStatementContextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ContextRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var recorded: [PluginStatementContext] = []

    var contexts: [PluginStatementContext] {
        lock.withLock { recorded }
    }

    private func record(_ context: PluginStatementContext) {
        lock.withLock { recorded.append(context) }
    }

    private static let empty = PluginQueryResult(
        columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0
    )

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult { Self.empty }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        record(context)
        return Self.empty
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record(context)
        return Self.empty
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record(context)
        return Self.empty
    }

    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        record(context)
        return AsyncThrowingStream { $0.finish() }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

struct PluginDriverAdapterStatementContextTests {
    private func makeAdapter(_ type: DatabaseType, driver: ContextRecordingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    @Test("Every entry point tells the driver a proven MongoDB read is a read")
    func mongoReadIsMarkedOnEveryEntryPoint() async throws {
        let driver = ContextRecordingDriver()
        let adapter = makeAdapter(.mongodb, driver: driver)
        let read = #"db.orders.find({status: "open"}).limit(10)"#

        _ = try await adapter.execute(query: read)
        _ = try await adapter.executeParameterized(query: read, parameters: [1])
        _ = try await adapter.executeUserQuery(query: read, rowCap: 100, parameters: nil)
        for try await _ in adapter.streamRows(query: read) {}

        #expect(driver.contexts.count == 4)
        #expect(driver.contexts.allSatisfy { $0.readOnly })
    }

    @Test(
        "A MongoDB statement that is not a proven read is not marked",
        arguments: ["db.orders.insertOne({a: 1})", "db.orders.find({}).forEach(function (d) { print(d) })"]
    )
    func mongoWriteIsNotMarked(statement: String) async throws {
        let driver = ContextRecordingDriver()
        _ = try await makeAdapter(.mongodb, driver: driver).executeUserQuery(query: statement, rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readOnly } == [false])
    }

    /// A SQL driver ignores the flag, so its statements are not classified for it.
    @Test("A SQL read is not marked")
    func sqlReadIsNotMarked() async throws {
        let driver = ContextRecordingDriver()
        _ = try await makeAdapter(.postgresql, driver: driver).executeUserQuery(query: "SELECT 1", rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readOnly } == [false])
    }
}
