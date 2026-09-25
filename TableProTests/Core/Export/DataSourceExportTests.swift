//
//  DataSourceExportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private protocol StubFormat: ExportFormatPlugin {}

private extension StubFormat {
    static var pluginVersion: String { "1.0.0" }
    static var pluginDescription: String { pluginName }
    static var formatDisplayName: String { pluginName }
    static var defaultFileExtension: String { formatId }
    static var iconName: String { "doc" }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        ExportFormatResult()
    }
}

private final class StubCSVFormat: StubFormat, @unchecked Sendable {
    static let pluginName = "CSV"
    static let formatId = "csv"
    init() {}
}

private final class StubSQLFormat: StubFormat, @unchecked Sendable {
    static let pluginName = "SQL"
    static let formatId = "sql"
    static let excludedDatabaseTypeIds = ["MongoDB", "Redis"]
    init() {}
}

private final class StubMQLFormat: StubFormat, @unchecked Sendable {
    static let pluginName = "MQL"
    static let formatId = "mql"
    static let supportedDatabaseTypeIds = ["MongoDB"]
    init() {}
}

@MainActor
struct DataSourceExportTests {
    private func request(
        scopes: [DataSourceExportScope] = [],
        initialScopeId: String? = nil
    ) -> DataSourceExportRequest {
        DataSourceExportRequest(
            title: "orders.csv",
            suggestedFileName: "orders",
            scopes: scopes,
            initialScopeId: initialScopeId
        )
    }

    private func scope(_ id: String, rowCount: Int? = nil) -> DataSourceExportScope {
        DataSourceExportScope(id: id, title: id, rowCount: rowCount) {
            QueryResultExportDataSource(
                detachedRows: TableRows(),
                databaseTypeId: DataSourceExportRequest.dataFileTypeId
            )
        }
    }

    private func formatIds(for databaseTypeId: String) -> [String] {
        ExportFormatCatalog
            .available([StubMQLFormat(), StubSQLFormat(), StubCSVFormat()], forDatabaseTypeId: databaseTypeId)
            .map { type(of: $0).formatId }
    }

    private func tableRows() -> TableRows {
        TableRows.from(
            queryRows: [["1", "Ada"], ["2", "O'Brien"], ["3", .null]],
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INTEGER"), .text(rawType: "TEXT")]
        )
    }

    private func streamedRows(of dataSource: any PluginExportDataSource) async throws -> [[PluginCellValue]] {
        var rows: [[PluginCellValue]] = []
        for try await element in dataSource.streamRows(table: "orders", databaseName: "") {
            guard case .rows(let batch) = element else { continue }
            rows.append(contentsOf: batch)
        }
        return rows
    }

    @Test("A data source export has no connection and filters formats by its own type id")
    func dataSourceModeIsConnectionless() {
        let mode = ExportMode.dataSource(request())
        #expect(mode.connection == nil)
        #expect(mode.formatDatabaseTypeId == "DataFile")
        #expect(!mode.listsDatabaseObjects)
        #expect(mode.suggestedFileName == "orders")
    }

    @Test("A table export keeps filtering formats by its connection's type")
    func tablesModeFiltersByConnectionType() {
        let connection = TestFixtures.makeConnection(type: .mongodb)
        let mode = ExportMode.tables(connection: connection, preselection: .tables(names: [], scope: nil))
        #expect(mode.connection?.id == connection.id)
        #expect(mode.formatDatabaseTypeId == DatabaseType.mongodb.rawValue)
        #expect(mode.listsDatabaseObjects)
        #expect(mode.suggestedFileName == nil)
    }

    @Test("The data file type offers every format that does not name its engines, and not MongoDB-only MQL")
    func dataFileTypeExcludesEngineSpecificFormats() {
        #expect(formatIds(for: DataSourceExportRequest.dataFileTypeId) == ["csv", "sql"])
    }

    @Test("A format's own engine list still decides for a connection type")
    func engineListsStillApply() {
        #expect(formatIds(for: "MongoDB") == ["csv", "mql"])
        #expect(formatIds(for: "MySQL") == ["csv", "sql"])
    }

    @Test("A supported list wins over an excluded list")
    func supportedListWins() {
        #expect(ExportFormatCatalog.accepts(
            databaseTypeId: "MongoDB",
            supportedDatabaseTypeIds: ["MongoDB"],
            excludedDatabaseTypeIds: ["MongoDB"]
        ))
        #expect(!ExportFormatCatalog.accepts(
            databaseTypeId: "DataFile",
            supportedDatabaseTypeIds: ["MongoDB"],
            excludedDatabaseTypeIds: []
        ))
        #expect(ExportFormatCatalog.accepts(
            databaseTypeId: "DataFile",
            supportedDatabaseTypeIds: [],
            excludedDatabaseTypeIds: ["MongoDB", "Redis"]
        ))
    }

    @Test("The initial scope is the one named, or the first when none or an unknown one is named")
    func initialScopeResolution() {
        let scopes = [scope("all"), scope("visible"), scope("selected")]
        #expect(request(scopes: scopes, initialScopeId: "selected").initialScope?.id == "selected")
        #expect(request(scopes: scopes).initialScope?.id == "all")
        #expect(request(scopes: scopes, initialScopeId: "gone").initialScope?.id == "all")
        #expect(request().initialScope == nil)
        #expect(request(scopes: scopes).scope(withId: nil) == nil)
    }

    @Test("A detached data source quotes identifiers and escapes literals the ANSI way")
    func detachedDataSourceQuotesAnsi() {
        let dataSource = QueryResultExportDataSource(
            detachedRows: tableRows(),
            databaseTypeId: DataSourceExportRequest.dataFileTypeId
        )
        #expect(dataSource.databaseTypeId == "DataFile")
        #expect(dataSource.quoteIdentifier("order \"items\"") == "\"order \"\"items\"\"\"")
        #expect(dataSource.quoteIdentifier("`name`") == "\"`name`\"")
        #expect(dataSource.escapeStringLiteral("O'Brien\\n") == "O''Brien\\n")
    }

    @Test("A detached data source streams every row, or only the rows it was given in that order")
    func detachedDataSourceStreamsRowSubset() async throws {
        let all = QueryResultExportDataSource(detachedRows: tableRows(), databaseTypeId: "DataFile")
        let allRows = try await streamedRows(of: all)
        #expect(allRows.count == 3)
        #expect(try await all.fetchApproximateRowCount(table: "orders", databaseName: "") == 3)

        let subset = QueryResultExportDataSource(
            detachedRows: tableRows(),
            rowIndices: [2, 7, 0],
            databaseTypeId: "DataFile"
        )
        let subsetRows = try await streamedRows(of: subset)
        #expect(subsetRows == [["3", .null], ["1", "Ada"]])
        #expect(try await subset.fetchApproximateRowCount(table: "orders", databaseName: "") == 2)
    }
}
