//
//  QueryHistoryEntryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("QueryHistoryEntry")
struct QueryHistoryEntryTests {
    private func makeEntry(
        query: String,
        executionTime: TimeInterval = 0.1,
        rowCount: Int = 10,
        wasSuccessful: Bool = true
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: UUID(),
            databaseName: "test",
            databaseType: .postgresql,
            source: .editor,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful
        )
    }

    @Test("queryPreview truncates long queries")
    func queryPreviewTruncatesLongQuery() {
        let entry = makeEntry(query: String(repeating: "SELECT ", count: 30))
        #expect(entry.queryPreview.hasSuffix("…"))
    }

    @Test("queryPreview preserves short queries")
    func queryPreviewPreservesShortQuery() {
        #expect(makeEntry(query: "SELECT 1").queryPreview == "SELECT 1;")
    }

    @Test("singleLinePreview collapses a multi-line statement onto one line")
    func singleLinePreviewCollapsesNewlines() {
        let entry = makeEntry(query: "SELECT id,\n       name\n  FROM users\n WHERE active = true")
        #expect(entry.singleLinePreview == "SELECT id, name FROM users WHERE active = true")
        #expect(entry.singleLinePreview.contains("\n") == false)
    }

    @Test("statementType is classified from the query when not supplied")
    func statementTypeIsClassified() {
        #expect(makeEntry(query: "SELECT 1").statementType == .select)
        #expect(makeEntry(query: "insert into t values (1)").statementType == .insert)
        #expect(makeEntry(query: "  -- a comment\n UPDATE t SET a = 1").statementType == .update)
        #expect(makeEntry(query: "DROP TABLE t").statementType == .ddl)
    }

    @Test("a negative row count reads as unknown rather than zero rows")
    func negativeRowCountIsUnknown() {
        let entry = makeEntry(query: "ALTER TABLE t ADD COLUMN c INT", rowCount: -1)
        #expect(entry.hasKnownRowCount == false)
        #expect(entry.formattedRowCount == "–")
    }

    @Test("an unmeasured duration is reported as unmeasured, not as zero")
    func zeroDurationIsUnmeasured() {
        #expect(makeEntry(query: "SELECT 1", executionTime: 0).hasMeasuredDuration == false)
        #expect(makeEntry(query: "SELECT 1", executionTime: 0.02).hasMeasuredDuration)
    }

    @Test("formattedExecutionTime switches unit at one second")
    func formattedExecutionTimeUnits() {
        #expect(makeEntry(query: "SELECT 1", executionTime: 0.25).formattedExecutionTime == "250 ms")
        #expect(makeEntry(query: "SELECT 1", executionTime: 1.5).formattedExecutionTime == "1.50 s")
    }

    @Test("a sub-millisecond query reads as under a millisecond, not as zero")
    func subMillisecondDurationIsNotZero() {
        let entry = makeEntry(query: "SELECT 1", executionTime: 0.0004)
        #expect(entry.formattedExecutionTime == String(localized: "<1 ms"))
        #expect(entry.formattedExecutionTime.hasPrefix("0") == false)
    }

    @Test("a file-backed database shows its file name, not its whole path")
    func fileBackedDatabaseShowsFileName() {
        let entry = QueryHistoryEntry(
            query: "SELECT 1",
            connectionId: UUID(),
            databaseName: "/Users/someone/Library/Containers/tmp/Chinook.sqlite",
            databaseType: .sqlite,
            source: .editor,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        #expect(entry.databaseDisplayName == "Chinook.sqlite")
    }

    @Test("a server database name is left alone")
    func serverDatabaseNameIsUnchanged() {
        let entry = makeEntry(query: "SELECT 1")
        #expect(entry.databaseDisplayName == "test")
    }
}
