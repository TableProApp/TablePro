//
//  SQLExportDropClauseTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

/// `DROP ... CASCADE` follows the engine, because it is not portable.
///
/// Measured: MariaDB accepts it and the manual says it does nothing ("permitted to make porting
/// easier"); sqlite3 rejects `DROP TABLE IF EXISTS "fields" CASCADE;` outright with
/// `near "CASCADE": syntax error`. The clause was previously emitted for every engine.
struct SQLExportDropClauseTests {

    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let supportsCascadeDrop: Bool

        init(databaseTypeId: String, supportsCascadeDrop: Bool) {
            self.databaseTypeId = databaseTypeId
            self.supportsCascadeDrop = supportsCascadeDrop
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
                continuation.yield(.rows([[.text("1")]]))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            "CREATE TABLE \(table) (id INTEGER)"
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    /// Declares no capability at all, so what it answers is the protocol extension's default.
    private final class SilentExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "SQLite"

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { identifier }
        func escapeStringLiteral(_ value: String) -> String { value }
        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private func dump(databaseTypeId: String, supportsCascadeDrop: Bool) async throws -> String {
        try await SQLExportHarness.shared.dump(
            tables: [
                PluginExportTable(
                    name: "fields",
                    databaseName: "",
                    tableType: "table",
                    optionValues: [true, true, true],
                    schema: nil
                )
            ],
            dataSource: StubExportDataSource(
                databaseTypeId: databaseTypeId, supportsCascadeDrop: supportsCascadeDrop)
        ).text
    }

    @Test("An engine that does not take CASCADE gets a plain DROP")
    func engineWithoutCascade() async throws {
        let sql = try await dump(databaseTypeId: "MySQL", supportsCascadeDrop: false)
        #expect(sql.contains("DROP TABLE IF EXISTS `fields`;"))
        #expect(!sql.contains("CASCADE"))
    }

    /// PostgreSQL is the engine the clause was written for: it drops dependent views with it.
    @Test("An engine that takes CASCADE keeps it")
    func engineWithCascade() async throws {
        let sql = try await dump(databaseTypeId: "PostgreSQL", supportsCascadeDrop: true)
        #expect(sql.contains("DROP TABLE IF EXISTS `fields` CASCADE;"))
    }

    /// The default is the answer that is never a syntax error. This asserts the protocol
    /// extension's own value, so flipping that default fails here rather than shipping a dump
    /// SQLite refuses.
    @Test("A data source that declares nothing gets no CASCADE")
    func defaultIsNoCascade() {
        let source: any PluginExportDataSource = SilentExportDataSource()
        #expect(!source.supportsCascadeDrop)
    }
}
