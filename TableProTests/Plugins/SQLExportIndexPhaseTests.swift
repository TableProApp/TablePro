//
//  SQLExportIndexPhaseTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL export index phase")
struct SQLExportIndexPhaseTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let indexDDL: [String: [String]]
        let failingTables: Set<String>

        init(
            databaseTypeId: String = "PostgreSQL",
            indexDDL: [String: [String]] = [:],
            failingTables: Set<String> = []
        ) {
            self.databaseTypeId = databaseTypeId
            self.indexDDL = indexDDL
            self.failingTables = failingTables
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

        func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
            if failingTables.contains(table) {
                throw StubError.unreadable
            }
            return indexDDL[table] ?? []
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

    private enum StubError: Error {
        case unreadable
    }

    private func table(_ name: String, optionValues: [Bool] = [true, true, true]) -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: "", tableType: "table", optionValues: optionValues, schema: nil)
    }

    private func runExport(
        tables: [PluginExportTable],
        dataSource: StubExportDataSource
    ) async throws -> (dump: String, result: ExportFormatResult) {
        let output = try await SQLExportHarness.shared.dump(tables: tables, dataSource: dataSource)
        return (output.text, output.result)
    }

    private func offset(of needle: String, in dump: String) throws -> Int {
        let range = try #require(dump.range(of: needle), "\(needle) missing from the dump")
        return dump.distance(from: dump.startIndex, to: range.lowerBound)
    }

    @Test("A driver that reports index DDL gets it into the dump")
    func indexesReachTheDump() async throws {
        let source = StubExportDataSource(
            indexDDL: ["orders": ["CREATE INDEX idx_orders_day ON orders (day)"]])

        let (dump, result) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(dump.contains("CREATE INDEX idx_orders_day ON orders (day);"))
        #expect(result.warnings.isEmpty)
    }

    @Test("Index statements are written after the rows, the way every engine's own dump tool does")
    func indexesFollowTheData() async throws {
        let source = StubExportDataSource(
            indexDDL: ["orders": ["CREATE INDEX idx_orders_day ON orders (day)"]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(try offset(of: "INSERT INTO", in: dump) < offset(of: "CREATE INDEX", in: dump))
    }

    @Test("Index statements are written after the deferred foreign keys")
    func indexesFollowDeferredConstraints() async throws {
        let source = StubExportDataSource(
            indexDDL: ["orders": ["CREATE INDEX idx_orders_day ON orders (day)"]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(try offset(of: "CREATE TABLE orders", in: dump) < offset(of: "CREATE INDEX", in: dump))
    }

    @Test("Only the statements the driver reported are written, in the order it reported them")
    func statementsAreWrittenVerbatim() async throws {
        let source = StubExportDataSource(indexDDL: ["orders": [
            "CREATE INDEX idx_a ON orders (a)",
            "CREATE UNIQUE INDEX idx_b ON orders (b) WHERE b > 0"
        ]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(dump.components(separatedBy: "CREATE INDEX").count - 1 == 1)
        #expect(dump.contains("CREATE UNIQUE INDEX idx_b ON orders (b) WHERE b > 0;"))
        #expect(try offset(of: "idx_a", in: dump) < offset(of: "idx_b", in: dump))
    }

    @Test("A table with Structure unticked contributes no index statements")
    func structureGatesTheIndexPhase() async throws {
        let source = StubExportDataSource(
            indexDDL: ["orders": ["CREATE INDEX idx_orders_day ON orders (day)"]])

        let (dump, _) = try await runExport(
            tables: [table("orders", optionValues: [false, false, true])], dataSource: source)

        #expect(!dump.contains("CREATE INDEX"))
    }

    @Test("A statement the driver left unterminated is terminated")
    func statementsAreTerminated() async throws {
        let source = StubExportDataSource(
            indexDDL: ["orders": ["CREATE INDEX idx_orders_day ON orders (day)"]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(dump.contains("(day);"))
        #expect(!dump.contains("(day);;"))
    }

    @Test("An unreadable index list is named in the warnings and does not fail the export")
    func unreadableIndexesAreReported() async throws {
        let source = StubExportDataSource(
            indexDDL: ["customers": ["CREATE INDEX idx_customers_name ON customers (name)"]],
            failingTables: ["orders"])

        let (dump, result) = try await runExport(
            tables: [table("orders"), table("customers")], dataSource: source)

        #expect(result.warnings.contains { $0.contains("Could not fetch indexes for") && $0.contains("orders") })
        #expect(dump.contains("CREATE INDEX idx_customers_name ON customers (name);"))
        #expect(dump.contains("-- Warning: failed to fetch indexes for orders"))
    }

    @Test("A table whose driver reports no indexes writes no index section")
    func noIndexesWritesNothing() async throws {
        let source = StubExportDataSource()

        let (dump, result) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(!dump.contains("CREATE INDEX"))
        #expect(result.warnings.isEmpty)
    }
}
