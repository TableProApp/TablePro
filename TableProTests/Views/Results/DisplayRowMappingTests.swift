//
//  DisplayRowMappingTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@testable import TablePro

@Suite("DisplayRowMapping")
struct DisplayRowMappingTests {
    private func makeTableRows() -> TableRows {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
            Row(id: .existing(3), values: [.null, .text("d")]),
        ]
        return TableRows(
            rows: rows,
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    @Test("with no display filter, a display index maps to the same array index")
    func identityMappingWithoutFilter() {
        let tableRows = makeTableRows()
        #expect(DisplayRowMapping.rowIndex(forDisplay: 0, displayIDs: nil, in: tableRows) == 0)
        #expect(DisplayRowMapping.rowIndex(forDisplay: 2, displayIDs: nil, in: tableRows) == 2)
        #expect(DisplayRowMapping.row(forDisplay: 3, displayIDs: nil, in: tableRows)?.id == .existing(3))
    }

    @Test("out-of-range display index returns nil without a filter")
    func outOfRangeWithoutFilter() {
        let tableRows = makeTableRows()
        #expect(DisplayRowMapping.rowIndex(forDisplay: 4, displayIDs: nil, in: tableRows) == nil)
        #expect(DisplayRowMapping.rowIndex(forDisplay: -1, displayIDs: nil, in: tableRows) == nil)
    }

    @Test("a filtered display position resolves to the underlying array row, not the raw position")
    func filteredMappingResolvesUnderlyingRow() {
        let tableRows = makeTableRows()
        let displayIDs: [RowID] = [.existing(0), .existing(2)]

        #expect(DisplayRowMapping.rowIndex(forDisplay: 0, displayIDs: displayIDs, in: tableRows) == 0)
        #expect(DisplayRowMapping.rowIndex(forDisplay: 1, displayIDs: displayIDs, in: tableRows) == 2)

        let resolved = DisplayRowMapping.row(forDisplay: 1, displayIDs: displayIDs, in: tableRows)
        #expect(resolved?.id == .existing(2))
        #expect(resolved?.values == tableRows.rows[2].values)
    }

    @Test("out-of-range display index returns nil with a filter")
    func outOfRangeWithFilter() {
        let tableRows = makeTableRows()
        let displayIDs: [RowID] = [.existing(0), .existing(2)]
        #expect(DisplayRowMapping.row(forDisplay: 2, displayIDs: displayIDs, in: tableRows) == nil)
    }
}
