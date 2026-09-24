//
//  TransferFailureReportTests.swift
//  TableProTests
//

import AppKit
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

    @Test("The box names a hidden character and the copy keeps the database's own text")
    func hiddenCharactersAreShownButCopiedVerbatim() {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = TransferReportClipboard()
        ClipboardService.shared = clipboard

        let report = "Line 3: unrecognized token: \"\u{8}\""
        let view = TransferReportView(report: report)
        view.copyReport()

        let shown = view.subviews
            .compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
            .first?
            .string
        #expect(shown == "Line 3: unrecognized token: \"<BS>\"")
        #expect(clipboard.text == report)
    }

    /// A failed SQL Server batch can run to tens of millions of units, and the box lays its text out on the main
    /// thread, so it shows the start of it and leaves the rest to the copy.
    @Test("The box shows the start of a long report and the copy carries all of it")
    func longReportIsCutInTheBoxButCopiedWhole() {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = TransferReportClipboard()
        ClipboardService.shared = clipboard

        let statement = "INSERT INTO files VALUES (1, 0x" + String(repeating: "A1", count: 500_000) + ");"
        let view = TransferReportView(shown: statement, copied: statement)
        view.copyReport()

        let shown = view.subviews
            .compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
            .first?
            .string ?? ""
        #expect((shown as NSString).length == TransferReportView.shownLengthLimit + 1)
        #expect(shown.hasSuffix("\u{2026}"))
        #expect(statement.hasPrefix(String(shown.dropLast())))
        #expect(clipboard.text == statement)
    }

    @Test("A cut report never splits a character in two")
    func cutKeepsCharactersWhole() {
        let lead = String(repeating: "a", count: TransferReportView.shownLengthLimit - 1)
        #expect(TransferReportView.shownText(lead + "\u{1F600}tail") == lead + "\u{2026}")
    }

    @Test("A report within the limit is shown as it is")
    func shortReportIsShownWhole() {
        let report = String(repeating: "b", count: TransferReportView.shownLengthLimit)
        #expect(TransferReportView.shownText(report) == report)
    }

    /// A SQL Server batch raises one error per statement that failed, up to a thousand, one line each, and an alert
    /// grows to fit its text, so the alert names the first few and Copy Details carries them all.
    @Test("A failure with many errors names the first few in the alert and copies them all")
    func manyErrorsAreCutInTheAlertButCopiedWhole() throws {
        let errors = (1...1_000).map { "Line \($0 + 2): Violation of PRIMARY KEY constraint 'PK_t'. Key (\($0))." }
        let failure = PluginImportError.statementFailed(
            statement: "INSERT t VALUES (1)",
            line: 3,
            underlyingError: TransferReportStubError(message: errors.joined(separator: "\n"))
        )

        let text = TransferResultAlert.importFailureText(for: failure)
        let limit = TransferResultAlert.shownErrorLineLimit
        #expect(text.components(separatedBy: "\n").count == limit + 1)
        #expect(text.contains(errors[limit - 1]))
        #expect(!text.contains(errors[limit]))

        let copied = try #require(TransferResultAlert.failureReport(for: failure))
        #expect(copied.contains(errors[999]))
    }

    @Test("An error line too long for the alert is cut there and copied whole")
    func longErrorLineIsCutInTheAlertButCopiedWhole() throws {
        let reason = "Line 4: Incorrect syntax near '" + String(repeating: "x", count: 100_000) + "'."
        let failure = PluginImportError.statementFailed(
            statement: "SELECT 1",
            line: 3,
            underlyingError: TransferReportStubError(message: reason)
        )

        let text = TransferResultAlert.importFailureText(for: failure)
        #expect((text as NSString).length < TransferResultAlert.shownErrorLengthLimit + 200)
        #expect(text.contains("Line 4: Incorrect syntax near 'xxx"))

        let copied = try #require(TransferResultAlert.failureReport(for: failure))
        #expect(copied.contains(reason))
    }

    @Test("A failure with a few errors names each of them")
    func fewErrorsAreShownWhole() {
        let failure = PluginImportError.statementFailed(
            statement: "SELECT 1",
            line: 3,
            underlyingError: TransferReportStubError(message: "Line 4: first\nLine 5: second")
        )
        let text = TransferResultAlert.importFailureText(for: failure)
        #expect(text.hasSuffix("Line 4: first\nLine 5: second"))
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

    var copiedImages: [NSImage] = []

    func writeImage(_ image: NSImage) {
        copiedImages.append(image)
    }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { false }
}
