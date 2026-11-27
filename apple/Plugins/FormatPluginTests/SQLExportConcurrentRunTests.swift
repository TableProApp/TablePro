//
//  SQLExportConcurrentRunTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private struct IndexReadFailure: Error {}

// A PostgreSQL table whose id defaults from a sequence, and whose indexes cannot be read.
private final class SequenceTableSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    private let sequenceDDL: String
    private let pause: ExportPause?

    init(sequenceDDL: String, pause: ExportPause? = nil) {
        self.sequenceDDL = sequenceDDL
        self.pause = pause
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
            continuation.yield(.rows([[.text("1")]]))
            continuation.finish()
        }
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        await pause?.hold()
        return [PluginSequenceInfo(name: "id_seq", ddl: sequenceDDL)]
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        "CREATE TABLE \(quoteIdentifier(table)) (id INTEGER DEFAULT nextval('id_seq'))"
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        throw IndexReadFailure()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

struct SQLExportConcurrentRunTests {
    // One name, two definitions: the name is what a run records once written.
    private static let ordersSequence = #"CREATE SEQUENCE "id_seq" START WITH 100"#
    private static let invoicesSequence = #"CREATE SEQUENCE "id_seq" START WITH 200"#

    private func table(_ name: String) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "",
            tableType: "table",
            optionValues: [true, true, true],
            schema: nil,
            kind: .table)
    }

    private func withoutTimestamp(_ dump: String) -> String {
        dump.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-- Generated: ") }
            .joined(separator: "\n")
    }

    // Every macOS window and iOS scene gets the same plugin instance, so a second export can start while one runs.
    @Test(
        "Two SQL exports on one plugin each write their own sequence and report only their own failures",
        .timeLimit(.minutes(1)))
    func overlappingExportsKeepTheirOwnBookkeeping() async throws {
        let orders = [table("orders")]
        let invoices = [table("invoices")]
        let ordersAlone = try await SQLExportHarness.shared.dump(
            tables: orders, dataSource: SequenceTableSource(sequenceDDL: Self.ordersSequence))
        let invoicesAlone = try await SQLExportHarness.shared.dump(
            tables: invoices, dataSource: SequenceTableSource(sequenceDDL: Self.invoicesSequence))

        let pause = ExportPause()
        let (held, other) = try await SQLExportHarness.shared.withPlugin { plugin in
            async let held = SQLExportHarness.dump(
                on: plugin, tables: orders,
                dataSource: SequenceTableSource(sequenceDDL: Self.ordersSequence, pause: pause))
            await pause.untilReached()
            let other = try await SQLExportHarness.dump(
                on: plugin, tables: invoices, dataSource: SequenceTableSource(sequenceDDL: Self.invoicesSequence))
            await pause.resume()
            return (try await held, other)
        }

        #expect(held.text.contains(Self.ordersSequence))
        #expect(other.text.contains(Self.invoicesSequence))
        #expect(held.result.warnings.contains { $0.contains("orders") })
        #expect(!held.result.warnings.contains { $0.contains("invoices") })
        #expect(other.result.warnings.contains { $0.contains("invoices") })
        #expect(!other.result.warnings.contains { $0.contains("orders") })
        #expect(held.result.warnings == ordersAlone.result.warnings)
        #expect(other.result.warnings == invoicesAlone.result.warnings)
        #expect(withoutTimestamp(held.text) == withoutTimestamp(ordersAlone.text))
        #expect(withoutTimestamp(other.text) == withoutTimestamp(invoicesAlone.text))
    }
}
