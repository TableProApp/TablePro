//
//  TransferFailureReportTests.swift
//  TableProTests
//

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
}
