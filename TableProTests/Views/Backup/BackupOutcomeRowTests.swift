//
//  BackupOutcomeRowTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Backup outcome rows")
struct BackupOutcomeRowTests {
    private func outcome(
        _ database: String,
        _ result: NativeDumpBatchOutcome.Result,
        directory: String = "/Users/me/Music/New"
    ) -> NativeDumpBatchOutcome {
        NativeDumpBatchOutcome(
            database: database,
            destination: URL(fileURLWithPath: "\(directory)/\(database)-2026-09-21-181500.sql"),
            result: result
        )
    }

    /// The reported case: a folder ending in `New/` above a database called `Music` read as the one
    /// path `/Users/Nick/Music/New/Music` once both were text in the same block (#3046).
    @Test("A failed database is its own row, never text joined to the folder")
    func failedRowStandsAlone() throws {
        let rows = BackupOutcomeRow.rows(for: [
            outcome("Music", .failed(message: "/opt/homebrew/bin/mysqldump: unknown variable 'ssl-mode=PREFERRED'"))
        ])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.database == "Music")
        #expect(row.state == .failed)
        #expect(row.size == nil)
        #expect(row.errorDetail == "/opt/homebrew/bin/mysqldump: unknown variable 'ssl-mode=PREFERRED'")
        #expect(!row.database.contains("/"))
    }

    /// `pg_dump` ends a refused connection with the generic hint and a permission failure with the
    /// query it was running, so keeping the last line alone threw the diagnosis away.
    @Test("Every line of the tool's output is kept")
    func multilineErrorSurvives() throws {
        let stderr = """
            pg_dump: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
            \tIs the server running on that host and accepting TCP/IP connections?
            """
        let rows = BackupOutcomeRow.rows(for: [outcome("sales", .failed(message: stderr))])
        let detail = try #require(rows.first?.errorDetail)
        #expect(detail.contains("Connection refused"))
        #expect(detail.contains("Is the server running"))
    }

    @Test("A written database carries its file and size")
    func succeededRow() throws {
        let rows = BackupOutcomeRow.rows(for: [outcome("production", .succeeded(bytes: 4_512_000))])
        let row = try #require(rows.first)
        #expect(row.state == .succeeded)
        #expect(row.fileName == "production-2026-09-21-181500.sql")
        #expect(row.size != nil)
        #expect(row.errorDetail == nil)
    }

    @Test("A cancelled database says so and claims no file")
    func cancelledRow() throws {
        let rows = BackupOutcomeRow.rows(for: [outcome("analytics", .cancelled)])
        let row = try #require(rows.first)
        #expect(row.state == .cancelled)
        #expect(row.size == nil)
        #expect(row.errorDetail == nil)
        #expect(BackupResultSheet.stateLabel(for: row) == String(localized: "Cancelled"))
    }

    /// A run where one of three failed keeps the other two visible, which is the whole reason the
    /// batch reports per database rather than one verdict.
    @Test("Every database in the run gets a row, in the order it ran")
    func everyDatabaseIsReported() {
        let rows = BackupOutcomeRow.rows(for: [
            outcome("Music", .failed(message: "boom")),
            outcome("production", .succeeded(bytes: 1_024)),
            outcome("analytics", .cancelled)
        ])
        #expect(rows.map(\.database) == ["Music", "production", "analytics"])
        #expect(rows.map(\.state) == [.failed, .succeeded, .cancelled])
        #expect(Set(rows.map(\.id)).count == 3)
    }
}
