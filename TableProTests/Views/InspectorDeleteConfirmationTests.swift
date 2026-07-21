//
//  InspectorDeleteConfirmationTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("InspectorDeleteConfirmation")
struct InspectorDeleteConfirmationTests {
    @Test("An all-empty selection contains no data")
    func emptyRowsHaveNoData() {
        #expect(InspectorDeleteConfirmation.rowsContainData([["", ""], ["", ""]]) == false)
    }

    @Test("An empty selection contains no data")
    func noRowsHaveNoData() {
        #expect(InspectorDeleteConfirmation.rowsContainData([]) == false)
    }

    @Test("A selection with any non-empty cell contains data")
    func nonEmptyRowsHaveData() {
        #expect(InspectorDeleteConfirmation.rowsContainData([["", ""], ["", "x"]]) == true)
    }

    @Test("Delete title reflects the row count")
    func rowDeleteTitles() {
        #expect(InspectorDeleteConfirmation.rowDeleteTitle(count: 1) == "Delete this row?")
        #expect(InspectorDeleteConfirmation.rowDeleteTitle(count: 3).contains("3"))
    }
}
