//
//  MultiRowEditStateExpansionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct MultiRowEditStateExpansionTests {
    private func configure(_ state: MultiRowEditState, row: Int, columns: [String] = ["id", "payload", "notes"]) {
        state.configure(
            rowIDs: [RowID.existing(row)],
            allRows: [columns.map { "\($0)-\(row)" }],
            columns: columns,
            columnTypes: columns.map { _ in ColumnType.text(rawType: nil) }
        )
    }

    @Test("An expanded field stays expanded when another row is selected")
    func expansionSurvivesSelectionChange() {
        let state = MultiRowEditState()
        configure(state, row: 0)
        let firstID = state.fields[1].id
        state.toggleExpansion(ofColumn: 1)

        configure(state, row: 1)

        #expect(state.fields[1].id != firstID)
        #expect(state.expandedColumn == 1)
    }

    @Test("Deselecting and selecting a row keeps the expansion")
    func expansionSurvivesDeselection() {
        let state = MultiRowEditState()
        configure(state, row: 0)
        state.toggleExpansion(ofColumn: 1)

        state.fields = []
        configure(state, row: 2)

        #expect(state.expandedColumn == 1)
    }

    @Test("New columns collapse the expanded field")
    func columnsChangeCollapses() {
        let state = MultiRowEditState()
        configure(state, row: 0)
        state.toggleExpansion(ofColumn: 1)

        configure(state, row: 0, columns: ["id", "payload", "notes", "created_at"])

        #expect(state.expandedColumn == nil)
    }

    @Test("Toggling the expanded column collapses it, and toggling another moves it")
    func toggling() {
        let state = MultiRowEditState()
        configure(state, row: 0)

        state.toggleExpansion(ofColumn: 1)
        state.toggleExpansion(ofColumn: 2)
        #expect(state.expandedColumn == 2)

        state.toggleExpansion(ofColumn: 2)
        #expect(state.expandedColumn == nil)
    }

    @Test("Releasing the data collapses the expanded field")
    func releaseCollapses() {
        let state = MultiRowEditState()
        configure(state, row: 0)
        state.toggleExpansion(ofColumn: 1)

        state.releaseData()

        #expect(state.expandedColumn == nil)
    }
}
