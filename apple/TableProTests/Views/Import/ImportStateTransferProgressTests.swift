//
//  ImportStateTransferProgressTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ImportStateTransferProgressTests {
    @Test("An SQL import's bar follows the file's bytes read, and its amount still counts statements")
    func sqlImportFollowsBytesRead() {
        var state = ImportState(
            isImporting: true, processedStatements: 3, estimatedTotalStatements: 100, fileName: "dump.sql"
        )
        state.fileBytes = 1_000
        state.fileBytesRead = 250

        let progress = state.transferProgress

        #expect(progress.fraction == 0.25)
        #expect(progress.amountText == "3 of about 100 statements")
    }

    @Test("Before the file's size is known, an SQL import's bar is statements done of the total")
    func noFileSizeFallsBackToStatements() {
        var state = ImportState(
            isImporting: true, processedStatements: 25, estimatedTotalStatements: 100, fileName: "dump.sql"
        )
        state.totalIsEstimate = false

        let progress = state.transferProgress

        #expect(progress.fraction == 0.25)
        #expect(progress.amountText == "25 of 100 statements")
    }

    @Test("A row import's bar ignores the file's bytes read")
    func rowImportIgnoresBytes() {
        var state = ImportState(
            isImporting: true, processedStatements: 30, estimatedTotalStatements: 120, fileName: "people.csv"
        )
        state.countsRows = true
        state.totalIsEstimate = false
        state.fileBytes = 1_000
        state.fileBytesRead = 900

        let progress = state.transferProgress

        #expect(progress.fraction == 0.25)
        #expect(progress.amountText == "30 of 120 rows")
    }
}
