//
//  TransferResultsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TransferResultsTests {
    @Test("A clean import reports its counts and nothing to keep")
    func importSucceeded() {
        let result = TransferResults.importSucceeded(
            result: PluginImportResult(executedStatements: 100_015, executionTime: 12.4)
        )

        #expect(result.outcome == .succeeded)
        #expect(result.title == "Import completed")
        #expect(result.message == "100015 statements executed\n12.40 seconds")
        #expect(result.details == nil)
        #expect(result.errorReport == nil)
        #expect(!result.returnsToForm)
        #expect(result.severity == .success)
    }

    @Test("An import that skipped statements shows them and offers the report")
    func importSucceededWithErrors() throws {
        let errors = [
            PluginImportResult.ImportStatementError(
                statement: "INSERT INTO users VALUES (1)",
                line: 412,
                errorMessage: "Duplicate entry"
            ),
        ]
        let result = TransferResults.importSucceeded(
            result: PluginImportResult(executedStatements: 9, executionTime: 1, skippedStatements: 1, errors: errors)
        )

        #expect(result.outcome == .succeededWithIssues)
        #expect(result.title == "Import completed with errors")
        let details = try #require(result.details)
        #expect(details.shown == "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)")
        #expect(details.copied == details.shown)
        let report = try #require(result.errorReport)
        #expect(report.totalSkipped == 1)
        #expect(report.errors.map(\.line) == [412])
        #expect(result.severity == .warning)
    }

    @Test("A failed statement keeps the form and shows the statement")
    func importFailedOnAStatement() throws {
        let failure = PluginImportError.statementFailed(
            statement: "INSERT t VALUES (1)",
            line: 7,
            underlyingError: TransferResultsStubError(message: "relation \"t\" does not exist")
        )
        let result = TransferResults.importFailed(error: failure)

        #expect(result.outcome == .failed)
        #expect(result.title == "Import failed")
        #expect(result.message == "Failed at line 7. relation \"t\" does not exist")
        let details = try #require(result.details)
        #expect(details.shown == "INSERT t VALUES (1)")
        #expect(details.copied == TransferResults.failureReport(for: failure))
        #expect(result.returnsToForm)
        #expect(result.severity == .error)
    }

    @Test("A failure that is not a statement carries no details")
    func importFailedWithoutAStatement() {
        let result = TransferResults.importFailed(error: TransferResultsStubError(message: "Not connected"))

        #expect(result.message == "Not connected")
        #expect(result.details == nil)
        #expect(result.returnsToForm)
    }

    @Test("A completed batch with a failed file is done with issues, a stopped one returns to its list")
    func batchOutcomes() {
        let file = RowImportRunItem(
            url: URL(fileURLWithPath: "/tmp/a.csv"),
            sourceName: "a.csv",
            formatId: "csv",
            targetTable: "a",
            columnMapping: [:],
            sourceFields: []
        )
        let failed = RowImportBatchReport(
            files: [file],
            outcomes: [.imported(PluginImportResult(executedStatements: 3, executionTime: 1, skippedStatements: 1))],
            ending: .completed,
            transaction: .untracked,
            executionTime: 1
        )
        let stopped = RowImportBatchReport(
            files: [file],
            outcomes: [.stopped(rowsBefore: 2)],
            ending: .stopped(file: 0),
            transaction: .untracked,
            executionTime: 1
        )

        #expect(TransferResults.batchImport(failed).outcome == .succeededWithIssues)
        #expect(TransferResults.batchImport(failed).title == "Import completed with errors")
        #expect(!TransferResults.batchImport(failed).returnsToForm)
        #expect(TransferResults.batchImport(stopped).outcome == .stopped)
        #expect(TransferResults.batchImport(stopped).returnsToForm)
        #expect(TransferResults.batchImport(stopped).details?.shown.contains("a.csv") == true)
    }

    @Test("An export with warnings says so and lists them after its notes")
    func exportSucceeded() {
        let clean = TransferResults.exportSucceeded(warnings: [], notes: ["Wrote 3 files."])
        #expect(clean.outcome == .succeeded)
        #expect(clean.title == "Export completed")
        #expect(clean.message == "Wrote 3 files.")

        let warned = TransferResults.exportSucceeded(warnings: ["Column x was cut."], notes: ["Wrote 3 files."])
        #expect(warned.outcome == .succeededWithIssues)
        #expect(warned.title == "Export completed with warnings")
        #expect(warned.message == "Wrote 3 files.\n\nColumn x was cut.")
    }

    @Test("A transfer reports its rows, tables and destination")
    func transferSucceeded() {
        let result = TransferResults.transferSucceeded(
            tableCount: 2,
            rowCount: 40,
            destinationName: "staging",
            warnings: []
        )
        #expect(result.outcome == .succeeded)
        #expect(result.title == "Transfer completed")
        #expect(result.message == "40 rows from 2 tables written to staging.")
    }
}

private struct TransferResultsStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
