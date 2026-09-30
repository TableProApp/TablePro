//
//  TrinoRowEditValuesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTrinoCore
import Testing

struct TrinoRowEditValuesTests {
    private let insert = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

    @Test
    func insertLeavesDefaultMarkedColumnsOut() {
        let values = TrinoRowEditValues.insertValues(
            insert,
            columns: ["id", "status"],
            insertedRowData: [0: [.text("1"), .text("__DEFAULT__")]],
            typeName: { _ in "varchar" }
        )
        #expect(values.map(\.name) == ["id"])
    }

    @Test
    func insertBuiltFromCellChangesLeavesDefaultMarkedColumnsOut() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [
                (columnIndex: 0, columnName: "id", oldValue: .null, newValue: .text("1")),
                (columnIndex: 1, columnName: "status", oldValue: .null, newValue: .text("__DEFAULT__"))
            ],
            originalRow: nil
        )
        let values = TrinoRowEditValues.insertValues(
            change, columns: ["id", "status"], insertedRowData: [:], typeName: { _ in "varchar" }
        )
        #expect(values.map(\.name) == ["id"])
    }

    @Test
    func insertOfOnlyDefaultsWritesNoStatement() {
        let values = TrinoRowEditValues.insertValues(
            insert,
            columns: ["status"],
            insertedRowData: [0: [.text("__DEFAULT__")]],
            typeName: { _ in "varchar" }
        )
        #expect(TrinoRowEditSQL.insert(qualifiedTable: "t", columns: values) == nil)
    }
}
