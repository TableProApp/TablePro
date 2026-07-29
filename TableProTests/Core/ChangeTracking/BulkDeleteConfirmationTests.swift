//
//  BulkDeleteConfirmationTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Bulk Delete Confirmation")
struct BulkDeleteConfirmationTests {
    @Test("No confirmation when nothing is being deleted")
    func testNotRequiredWithoutDeletes() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 0).isRequired == false)
    }

    @Test("Confirmation required once a row is marked for deletion")
    func testRequiredWithDeletes() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 1).isRequired == true)
        #expect(BulkDeleteConfirmation(deletedRowCount: 42).isRequired == true)
    }

    @Test("Title reports the row count for a bulk delete")
    func testTitleIncludesCount() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 12).title.contains("12"))
    }

    @Test("Single-row title differs from the bulk title")
    func testSingleRowTitleDiffersFromBulk() {
        let single = BulkDeleteConfirmation(deletedRowCount: 1).title
        let bulk = BulkDeleteConfirmation(deletedRowCount: 2).title
        #expect(single != bulk)
    }

    @Test("Confirm button is a specific, non-empty action title")
    func testConfirmButtonTitle() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 3).confirmButtonTitle.isEmpty == false)
    }
}
