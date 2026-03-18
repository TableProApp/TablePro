//
//  QueryHistoryEntryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryEntry")
struct QueryHistoryEntryTests {
    @Test("queryPreview truncates long queries")
    func queryPreviewTruncatesLongQuery() {
        let entry = QueryHistoryEntry(
            query: String(repeating: "SELECT ", count: 30),
            connectionId: UUID(),
            databaseName: "test",
            executionTime: 0.1,
            rowCount: 10,
            wasSuccessful: true
        )
        #expect(entry.queryPreview.hasSuffix("..."))
    }

    @Test("queryPreview preserves short queries")
    func queryPreviewPreservesShortQuery() {
        let entry = QueryHistoryEntry(
            query: "SELECT 1",
            connectionId: UUID(),
            databaseName: "test",
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        )
        #expect(entry.queryPreview == "SELECT 1;")
    }
}
