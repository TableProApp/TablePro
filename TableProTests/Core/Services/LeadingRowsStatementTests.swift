//
//  LeadingRowsStatementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Leading-rows statements")
@MainActor
struct LeadingRowsStatementTests {
    private let dialect = SqlDialect.from(databaseTypeId: DatabaseType.cloudflareR2SQL.rawValue)

    private func bound(_ sql: String, rowCap: Int?, style: AutoLimitStyle = .limit) -> LeadingRowsStatement {
        LeadingRowsStatement.bound(sql, rowCap: rowCap, maximumRows: 10_000, autoLimitStyle: style, lexicalDialect: dialect)
    }

    @Test("A capped read fetches one row past the cap, so a trimmed result is still detected")
    func cappedRead() {
        #expect(bound("SELECT * FROM logs.events", rowCap: 1_000)
            == LeadingRowsStatement(sql: "SELECT * FROM logs.events\nLIMIT 1001", rowCap: 1_000))
    }

    @Test("An uncapped read asks for the engine's ceiling instead of taking its smaller default")
    func uncappedRead() {
        #expect(bound("SELECT * FROM logs.events", rowCap: nil)
            == LeadingRowsStatement(sql: "SELECT * FROM logs.events\nLIMIT 10000", rowCap: nil))
    }

    @Test("A cap at or past the ceiling fetches the ceiling")
    func capPastCeiling() {
        #expect(bound("SELECT 1", rowCap: 50_000) == LeadingRowsStatement(sql: "SELECT 1\nLIMIT 10000", rowCap: 10_000))
    }

    @Test("A read the user already limited is sent as written")
    func explicitLimit() {
        #expect(bound("SELECT * FROM t LIMIT 5", rowCap: nil) == LeadingRowsStatement(sql: "SELECT * FROM t LIMIT 5", rowCap: nil))
    }

    @Test("A trailing semicolon is dropped and a trailing comment cannot swallow the clause")
    func trailingPunctuation() {
        #expect(bound("SELECT 1;  ", rowCap: nil).sql == "SELECT 1\nLIMIT 10000")
        #expect(bound("SELECT 1 -- all of it", rowCap: nil).sql == "SELECT 1 -- all of it\nLIMIT 10000")
    }

    @Test("A FETCH FIRST dialect gets FETCH FIRST, and a TOP dialect is left alone")
    func otherStyles() {
        #expect(bound("SELECT 1", rowCap: nil, style: .fetchFirst).sql == "SELECT 1\nFETCH FIRST 10000 ROWS ONLY")
        #expect(bound("SELECT 1", rowCap: nil, style: .top).sql == "SELECT 1")
    }

    @Test("Only row-producing reads on a leading-rows engine are touched")
    func resolveScope() {
        #expect(LeadingRowsStatement.resolve("SHOW TABLES IN logs", rowCap: nil, databaseType: .cloudflareR2SQL).sql
            == "SHOW TABLES IN logs")
        #expect(LeadingRowsStatement.resolve("SELECT * FROM t", rowCap: nil, databaseType: .cloudflareR2SQL).sql
            == "SELECT * FROM t\nLIMIT 10000")
        #expect(LeadingRowsStatement.resolve("SELECT * FROM t", rowCap: 100, databaseType: .postgresql)
            == LeadingRowsStatement(sql: "SELECT * FROM t", rowCap: 100))
    }

    @Test("A leading-rows engine is only counted on request")
    func rowCountPlan() {
        let unfiltered = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false, filterState: TabFilterState(), approximateRowCount: nil, threshold: 100_000,
            countsAutomatically: false
        )
        #expect(unfiltered == .skip)
    }

    @Test("A browse on a leading-rows engine refuses an offset and clamps its limit")
    func mcpBrowseLimit() throws {
        let leadingRows = PaginationCapability.leadingRowsOnly(maximumRows: 10_000)

        #expect(try MCPConnectionBridge.browseLimit(for: browse(offset: 0, limit: 50_000), pagination: leadingRows) == 10_000)
        #expect(throws: DatabaseAccessError.self) {
            try MCPConnectionBridge.browseLimit(for: browse(offset: 100, limit: 100), pagination: leadingRows)
        }
        #expect(try MCPConnectionBridge.browseLimit(for: browse(offset: 100, limit: 100), pagination: .offset) == 100)
    }

    @Test("An export from a leading-rows engine always states a limit no higher than the ceiling")
    func exportRowLimit() {
        let leadingRows = PaginationCapability.leadingRowsOnly(maximumRows: 10_000)

        #expect(ExportDataSourceAdapter.rowLimit(requested: nil, pagination: leadingRows) == 10_000)
        #expect(ExportDataSourceAdapter.rowLimit(requested: 20_000, pagination: leadingRows) == 10_000)
        #expect(ExportDataSourceAdapter.rowLimit(requested: 50, pagination: leadingRows) == 50)
        #expect(ExportDataSourceAdapter.rowLimit(requested: nil, pagination: .offset) == nil)
    }

    @Test("A query export that reached the engine's ceiling is named as partial")
    func queryExportCapWarning() {
        let leadingRows = PaginationCapability.leadingRowsOnly(maximumRows: 10_000)

        #expect(ExportService.leadingRowsCapWarning(exportedRows: 10_000, pagination: leadingRows) != nil)
        #expect(ExportService.leadingRowsCapWarning(exportedRows: 9_999, pagination: leadingRows) == nil)
        #expect(ExportService.leadingRowsCapWarning(exportedRows: 50_000, pagination: .offset) == nil)
    }

    private func browse(offset: Int, limit: Int) -> MCPBrowseRequest {
        MCPBrowseRequest(
            table: "events", columns: nil, filters: [], logicMode: .and, sort: [], limit: limit, offset: offset
        )
    }
}
