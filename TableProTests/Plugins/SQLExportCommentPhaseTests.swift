//
//  SQLExportCommentPhaseTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL export comments")
struct SQLExportCommentPhaseTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let commentDDL: [String: [String]]
        let failingTables: Set<String>

        init(
            databaseTypeId: String = "PostgreSQL",
            commentDDL: [String: [String]] = [:],
            failingTables: Set<String> = []
        ) {
            self.databaseTypeId = databaseTypeId
            self.commentDDL = commentDDL
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

        func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
            switch object.kind {
            case .view: return "CREATE OR REPLACE VIEW \(object.name) AS SELECT 1"
            case .materializedView: return "CREATE MATERIALIZED VIEW \(object.name) AS SELECT 1"
            case .routine: return "CREATE FUNCTION \(object.name)() RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql"
            default: return try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
            }
        }

        func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
            if failingTables.contains(table) {
                throw StubError.unreadable
            }
            return commentDDL[table] ?? []
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

    private func table(
        _ name: String,
        kind: PluginExportObjectKind = .table,
        optionValues: [Bool] = [true, true, true]
    ) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "",
            tableType: kind.rawValue,
            optionValues: optionValues,
            schema: nil,
            kind: kind)
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

    @Test("A driver that reports comment DDL gets it into the dump, terminated")
    func commentsReachTheDump() async throws {
        let source = StubExportDataSource(commentDDL: ["orders": [
            "COMMENT ON TABLE orders IS 'Orders table'",
            "COMMENT ON COLUMN orders.id IS 'Primary key'"
        ]])

        let (dump, result) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(dump.contains("COMMENT ON TABLE orders IS 'Orders table';"))
        #expect(dump.contains("COMMENT ON COLUMN orders.id IS 'Primary key';"))
        #expect(result.warnings.isEmpty)
    }

    @Test("A comment rides with its own object: after the CREATE, before the rows and the indexes")
    func commentsFollowTheCreate() async throws {
        let source = StubExportDataSource(
            commentDDL: ["orders": ["COMMENT ON TABLE orders IS 'Orders table'"]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(try offset(of: "CREATE TABLE orders", in: dump) < offset(of: "COMMENT ON TABLE", in: dump))
        #expect(try offset(of: "COMMENT ON TABLE", in: dump) < offset(of: "INSERT INTO", in: dump))
    }

    @Test("A view's comments sit in its own block, right after its CREATE")
    func viewCommentsFollowTheViewCreate() async throws {
        let source = StubExportDataSource(commentDDL: ["v_orders": [
            "COMMENT ON VIEW v_orders IS 'View comment'",
            "COMMENT ON COLUMN v_orders.id IS 'View column comment'"
        ]])

        let (dump, _) = try await runExport(
            tables: [table("v_orders", kind: .view)], dataSource: source)

        #expect(try offset(of: "CREATE OR REPLACE VIEW", in: dump) < offset(of: "COMMENT ON VIEW", in: dump))
        #expect(dump.contains("COMMENT ON COLUMN v_orders.id IS 'View column comment';"))
    }

    @Test("A materialized view's comment falls after its CREATE and before the next object header")
    func matviewCommentFollowsItsCreate() async throws {
        let source = StubExportDataSource(
            commentDDL: ["m_orders": ["COMMENT ON MATERIALIZED VIEW m_orders IS 'Matview comment'"]])

        let (dump, _) = try await runExport(
            tables: [
                table("m_orders", kind: .materializedView),
                table("r_sum", kind: .routine)
            ],
            dataSource: source)

        #expect(try offset(of: "CREATE MATERIALIZED VIEW", in: dump)
            < offset(of: "COMMENT ON MATERIALIZED VIEW", in: dump))
        #expect(try offset(of: "COMMENT ON MATERIALIZED VIEW", in: dump)
            < offset(of: "-- Routine: r_sum", in: dump))
    }

    @Test("A statement the driver already terminated is not terminated twice")
    func terminatedStatementsStaySingleTerminated() async throws {
        let source = StubExportDataSource(
            commentDDL: ["orders": ["COMMENT ON TABLE orders IS 'Orders table';"]])

        let (dump, _) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(dump.contains("IS 'Orders table';"))
        #expect(!dump.contains("IS 'Orders table';;"))
    }

    @Test("A source answering nothing writes no COMMENT ON anywhere")
    func noCommentsWritesNothing() async throws {
        let source = StubExportDataSource(databaseTypeId: "MySQL")

        let (dump, result) = try await runExport(tables: [table("orders")], dataSource: source)

        #expect(!dump.contains("COMMENT ON"))
        #expect(result.warnings.isEmpty)
    }

    @Test("A table with Structure unticked contributes no comment statements")
    func structureGatesTheCommentPhase() async throws {
        let source = StubExportDataSource(
            commentDDL: ["orders": ["COMMENT ON TABLE orders IS 'Orders table'"]])

        let (dump, _) = try await runExport(
            tables: [table("orders", optionValues: [false, true, true])], dataSource: source)

        #expect(!dump.contains("COMMENT ON"))
    }

    @Test("An unreadable comment list is named in the warnings and does not fail the export")
    func unreadableCommentsAreReported() async throws {
        let source = StubExportDataSource(
            commentDDL: ["customers": ["COMMENT ON TABLE customers IS 'Customers'"]],
            failingTables: ["orders"])

        let (dump, result) = try await runExport(
            tables: [table("orders"), table("customers")], dataSource: source)

        #expect(result.warnings.contains { $0.contains("Could not fetch comments for") && $0.contains("orders") })
        #expect(dump.contains("-- Warning: failed to fetch comments for orders"))
        #expect(dump.contains("COMMENT ON TABLE customers IS 'Customers';"))
        #expect(dump.contains("CREATE TABLE customers (id INTEGER);"))
        #expect(dump.contains("INSERT INTO"))
    }

    @Test("A routine is never asked for comments, so its definition is all that is written")
    func routinesAreNotAskedForComments() async throws {
        let source = StubExportDataSource(
            commentDDL: ["r_sum": ["COMMENT ON FUNCTION r_sum() IS 'never asked'"]])

        let (dump, _) = try await runExport(
            tables: [table("r_sum", kind: .routine)], dataSource: source)

        #expect(!dump.contains("COMMENT ON FUNCTION"))
    }

    @Test("A foreign table is never asked, because the dump writes CREATE TABLE for it")
    func foreignTablesAreNotAskedForComments() async throws {
        let source = StubExportDataSource(
            commentDDL: ["f_orders": ["COMMENT ON FOREIGN TABLE f_orders IS 'Foreign comment'"]])

        let (dump, result) = try await runExport(
            tables: [table("f_orders", kind: .foreignTable)], dataSource: source)

        #expect(dump.contains("CREATE TABLE f_orders"))
        #expect(!dump.contains("COMMENT ON FOREIGN TABLE"))
        #expect(result.warnings.isEmpty)
    }
}
