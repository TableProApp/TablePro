//
//  ImportSummaryTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ImportSummaryTextTests {
    @Test("A row import that matched rows lists each count and the failures")
    func rowImportSummary() {
        var tally = ImportRowTally(mode: .upsert)
        tally.updated = 9_500
        tally.inserted = 500
        let result = PluginImportResult(executedStatements: 10_000, executionTime: 1.5, skippedStatements: 1)

        let lines = TransferResultAlert.importSummary(result, rowTally: tally).components(separatedBy: "\n")

        #expect(lines == tally.summaryLines(failed: 1) + ["1.50 seconds"])
    }

    @Test("A SQL file import still counts statements")
    func statementSummary() {
        let result = PluginImportResult(executedStatements: 12, executionTime: 0.25)
        #expect(TransferResultAlert.importSummary(result) == "12 statements executed\n0.25 seconds")
    }
}
