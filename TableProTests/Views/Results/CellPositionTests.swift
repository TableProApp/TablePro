//
//  CellPositionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

struct RowVisualStateTests {
    @Test("Empty state has all flags false and empty modifiedColumns")
    func emptyState() {
        let state = RowVisualState.empty
        #expect(state.isDeleted == false)
        #expect(state.isInserted == false)
        #expect(state.modifiedColumns.isEmpty)
    }

    @Test("Deleted state reports isDeleted true")
    func deletedState() {
        let state = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
        #expect(state.isDeleted == true)
        #expect(state.isInserted == false)
    }

    @Test("Inserted state reports isInserted true")
    func insertedState() {
        let state = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
        #expect(state.isInserted == true)
        #expect(state.isDeleted == false)
    }

    @Test("Modified columns tracks column indices correctly")
    func modifiedColumns() {
        let state = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [1, 3, 5])
        #expect(state.modifiedColumns.count == 3)
        #expect(state.modifiedColumns.contains(1))
        #expect(state.modifiedColumns.contains(3))
        #expect(state.modifiedColumns.contains(5))
        #expect(!state.modifiedColumns.contains(2))
    }
}
