//
//  TransferFailureReportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Transfer failure report")
@MainActor
struct TransferFailureReportTests {
    private func failure(line: Int, message: String, statement: String) -> PluginImportResult.ImportStatementError {
        PluginImportResult.ImportStatementError(statement: statement, line: line, errorMessage: message)
    }

    @Test("The failing statement is reported alongside the line and the message")
    func statementIsIncluded() {
        let report = TransferResultAlert.failureReport(for: [
            failure(line: 12, message: "syntax error", statement: "INSERT INTO users VALUES (")
        ])
        #expect(report.contains("12"))
        #expect(report.contains("syntax error"))
        #expect(report.contains("INSERT INTO users VALUES ("))
    }

    /// A row import names its entry `row 12`, which the line number already says.
    @Test("A statement that only repeats the line number is left out")
    func rowPlaceholderIsSkipped() {
        let report = TransferResultAlert.failureReport(for: [
            failure(line: 12, message: "not null violation", statement: "row 12")
        ])
        #expect(report.contains("not null violation"))
        #expect(report.contains("row 12") == false)
    }

    @Test("An empty statement adds no trailing line")
    func emptyStatementIsSkipped() {
        let report = TransferResultAlert.failureReport(for: [
            failure(line: 3, message: "duplicate key", statement: "   ")
        ])
        #expect(report.hasSuffix("duplicate key"))
    }

    @Test("Failures are separated from one another")
    func failuresAreSeparated() {
        let report = TransferResultAlert.failureReport(for: [
            failure(line: 1, message: "first", statement: "SELECT 1"),
            failure(line: 2, message: "second", statement: "SELECT 2")
        ])
        #expect(report.contains("\n\n"))
        #expect(report.contains("SELECT 1"))
        #expect(report.contains("SELECT 2"))
    }

    // MARK: - The report a failed import carries

    @Test("A failed statement reports its line, its reason and the statement")
    func failedStatementReportsEverything() throws {
        let report = try #require(TransferResultAlert.failureReport(
            for: PluginImportError.statementFailed(
                statement: "INSERT INTO users VALUES (1)",
                line: 412,
                underlyingError: TransferReportStubError(message: "Duplicate entry '1' for key 'PRIMARY'")
            )
        ))
        #expect(report.contains("412"))
        #expect(report.contains("Duplicate entry '1' for key 'PRIMARY'"))
        #expect(report.contains("INSERT INTO users VALUES (1)"))
    }

    @Test("An error with no failing statement carries no report")
    func unstructuredErrorHasNoReport() {
        #expect(TransferResultAlert.failureReport(for: PluginImportError.importFailed("disk full")) == nil)
        #expect(TransferResultAlert.failureReport(for: nil) == nil)
    }

    /// The report is what the user has to send on to whoever can fix the data, so copying it must
    /// not depend on them knowing the accessory text is selectable.
    @Test("Copying the report writes it to the clipboard")
    func copyingWritesTheReport() {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = TransferReportClipboard()
        ClipboardService.shared = clipboard

        TransferReportView(report: "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)").copyReport()

        #expect(clipboard.text == "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)")
    }

    /// The alert's own text already names the line and the reason, so the box repeats neither.
    /// Copying still has to carry all three, or the pasted text does not stand on its own.
    @Test("Copying carries more than the box shows")
    func copyingCarriesMoreThanIsShown() {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = TransferReportClipboard()
        ClipboardService.shared = clipboard

        TransferReportView(
            shown: "INSERT INTO users VALUES (1)",
            copied: "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)"
        ).copyReport()

        #expect(clipboard.text?.contains("412") == true)
        #expect(clipboard.text?.contains("Duplicate entry") == true)
        #expect(clipboard.text?.contains("INSERT INTO users VALUES (1)") == true)
    }
}

private struct TransferReportStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class TransferReportClipboard: ClipboardProvider {
    var text: String?

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text }
    func writeCsv(_ csv: String) { text = csv }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { false }
}
