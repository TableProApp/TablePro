//
//  ExportServiceRedisTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Export service state")
struct ExportServiceRedisTests {

    @Test("ExportState initializes with correct defaults")
    func exportStateDefaults() {
        let state = ExportState()
        #expect(state.isExporting == false)
        #expect(state.currentTable == "")
        #expect(state.totalTables == 0)
        #expect(state.processedRows == 0)
        #expect(state.totalRows == 0)
        #expect(state.errorMessage == nil)
    }

    @MainActor @Test("ExportConfiguration uses formatId string")
    func exportConfigFormatId() {
        var config = ExportConfiguration()
        #expect(config.formatId == "csv")
        config.formatId = "json"
        #expect(config.formatId == "json")
    }

    @Test("ExportError descriptions are localized")
    func exportErrorDescriptions() {
        let error = ExportError.noTablesSelected
        #expect(error.errorDescription != nil)

        let formatError = ExportError.formatNotFound("parquet")
        #expect(formatError.errorDescription?.contains("parquet") == true)
    }
}
