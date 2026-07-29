//
//  InspectorRowInsertionTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("InspectorRowInsertion")
struct InspectorRowInsertionTests {
    @Test("A clicked row maps through displayToStore for above and below")
    func mapsClickedRow() {
        let displayToStore = [10, 11, 12]
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: 1, below: false, displayToStore: displayToStore, rowCount: 3) == 11)
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: 1, below: true, displayToStore: displayToStore, rowCount: 3) == 12)
    }

    @Test("A non-identity displayToStore (filtered or sorted view) resolves the store row")
    func nonIdentityMapping() {
        let displayToStore = [4, 0, 9]
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: 0, below: false, displayToStore: displayToStore, rowCount: 10) == 4)
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: 2, below: true, displayToStore: displayToStore, rowCount: 10) == 10)
    }

    @Test("No anchor inserts at the top for above and appends for below")
    func emptySelectionFallback() {
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: nil, below: false, displayToStore: [0, 1], rowCount: 2) == 0)
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: nil, below: true, displayToStore: [0, 1], rowCount: 2) == 2)
    }

    @Test("An out-of-range anchor falls back to top or append")
    func outOfRangeFallback() {
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: 5, below: false, displayToStore: [0, 1], rowCount: 2) == 0)
        #expect(InspectorRowInsertion.storeIndex(
            anchorDisplayRow: -1, below: true, displayToStore: [0, 1], rowCount: 2) == 2)
    }
}
