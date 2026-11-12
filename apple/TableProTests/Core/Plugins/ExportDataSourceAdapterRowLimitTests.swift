import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StreamRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var streamedQueries: [String] {
        lock.withLock { queries }
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        lock.withLock { queries.append(query) }
        return AsyncThrowingStream { $0.finish() }
    }

    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
}

// No stream of its own, so its rows reach the export through PluginKit's default, the way SAP HANA's do.
private final class CuttingQueryDriver: PluginDriverStub, @unchecked Sendable {
    private let rowCount: Int
    private let isCut: Bool

    init(rowCount: Int, isCut: Bool) {
        self.rowCount = rowCount
        self.isCut = isCut
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(
            columns: ["id"],
            columnTypeNames: ["INTEGER"],
            rows: (0..<rowCount).map { [.text(String($0))] },
            rowsAffected: 0,
            executionTime: 0,
            isTruncated: isCut
        )
    }

    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
}

// A SAP HANA export over 5,000,000 rows wrote the first 5,000,000 and reported success: the default
// stream dropped the result's cut, so nothing named the file as partial.
@MainActor
struct ExportDriverRowCutTests {
    private let orders = PluginExportTable(name: "orders", databaseName: "SALES", tableType: "table", schema: "SALES", kind: .table)

    private func exportAdapter(_ driver: CuttingQueryDriver, type: DatabaseType) -> ExportDataSourceAdapter {
        ExportDataSourceAdapter(
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: driver),
            databaseType: type
        )
    }

    private func rowCount(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> Int {
        var count = 0
        for try await element in stream {
            if case .rows(let rows) = element { count += rows.count }
        }
        return count
    }

    @Test("A table export the driver cut at its row limit is named as partial")
    func cutTableExportIsReported() async throws {
        let adapter = exportAdapter(CuttingQueryDriver(rowCount: 3, isCut: true), type: .sapHana)

        let exported = try await rowCount(adapter.streamRows(for: orders))

        #expect(exported == 3)
        #expect(adapter.cappedTableWarnings.count == 1)
        #expect(adapter.cappedTableWarnings.first?.contains("orders") == true)
        #expect(adapter.cappedTableWarnings.first?.contains("3") == true)
    }

    @Test("A table export the driver read whole carries no warning")
    func wholeTableExportIsNotReported() async throws {
        let adapter = exportAdapter(CuttingQueryDriver(rowCount: 3, isCut: false), type: .sapHana)

        let exported = try await rowCount(adapter.streamRows(for: orders))

        #expect(exported == 3)
        #expect(adapter.cappedTableWarnings.isEmpty)
    }

    @Test("A table export that reaches the engine's own ceiling is still named as partial")
    func engineCeilingIsStillReported() async throws {
        let adapter = exportAdapter(CuttingQueryDriver(rowCount: 10_000, isCut: false), type: .cloudflareR2SQL)

        _ = try await rowCount(adapter.streamRows(for: orders))

        #expect(adapter.cappedTableWarnings.count == 1)
    }

    @Test("A query export the driver cut is named as partial at the limit it declared")
    func cutQueryExportIsReported() async throws {
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .sapHana),
            pluginDriver: CuttingQueryDriver(rowCount: 3, isCut: true)
        )
        let source = StreamingQueryExportDataSource(query: "SELECT id FROM orders", driver: driver, databaseType: .sapHana)

        let exported = try await rowCount(source.streamRows(table: "result", databaseName: ""))

        #expect(exported == 3)
        #expect(source.driverRowCut == 3)
        #expect(ExportService.leadingRowsCapWarning(exportedRows: 3, pagination: .offset, driverCut: source.driverRowCut) != nil)
        #expect(ExportService.leadingRowsCapWarning(exportedRows: 3, pagination: .offset, driverCut: nil) == nil)
    }
}

struct ExportDataSourceAdapterRowLimitTests {
    private func streamedQuery(
        type: DatabaseType,
        table: String,
        schema: String,
        scope: PluginExportRowScope
    ) -> String? {
        let recorder = StreamRecordingDriver()
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: type), pluginDriver: recorder
        )
        let adapter = ExportDataSourceAdapter(driver: driver, databaseType: type)
        _ = adapter.streamRows(for: PluginExportTable(
            name: table, databaseName: schema, tableType: "table", schema: schema, kind: .table,
            rowScope: scope
        ))
        return recorder.streamedQueries.last
    }

    @Test("A scoped SQL Server export limits its rows with TOP")
    func sqlServerScopedExport() {
        let query = streamedQuery(
            type: .mssql, table: "orders", schema: "dbo",
            scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
        )
        #expect(query == "SELECT TOP 10 * FROM \"dbo\".\"orders\" WHERE total > 10")
    }

    @Test("A scoped Oracle export of one column limits its rows with FETCH FIRST and sorts nothing")
    func oracleScopedExport() {
        let query = streamedQuery(
            type: .oracle, table: "ORDERS", schema: "HR",
            scope: PluginExportRowScope(rowLimit: 10, columns: ["DOCUMENT"])
        )
        #expect(query == "SELECT \"DOCUMENT\" FROM \"HR\".\"ORDERS\" FETCH FIRST 10 ROWS ONLY")
    }

    @Test("A scoped MySQL export keeps LIMIT")
    func mysqlScopedExport() {
        let query = streamedQuery(
            type: .mysql, table: "orders", schema: "shop",
            scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
        )
        #expect(query == "SELECT * FROM \"shop\".\"orders\" WHERE total > 10 LIMIT 10")
    }
}
