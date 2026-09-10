//
//  RowWriteOperationBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Row write operation capture")
struct RowWriteOperationBuilderTests {
    private let columns = ["id", "name", "updated_at"]
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "users")

    private func operations(
        changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = [],
        primaryKeyColumns: [String] = ["id"],
        generatedColumns: Set<String> = [],
        containsTableOperation: Bool = false
    ) -> [RowWriteOperation] {
        RowWriteOperationBuilder.operations(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices,
            target: target,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            containsTableOperation: containsTableOperation
        )
    }

    private func cellEdit(column: String, index: Int, from old: PluginCellValue, to new: PluginCellValue) -> RowChange {
        RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(columnIndex: index, columnName: column, oldValue: old, newValue: new),
            ],
            originalRow: ["7", "Ada", "2026-01-01"]
        )
    }

    @Test("An edit records the row on both sides and names only the column it wrote")
    func updateCapturesBothImages() {
        let result = operations(changes: [cellEdit(column: "name", index: 1, from: "Ada", to: "Grace")])

        #expect(result.count == 1)
        #expect(result.first?.kind == .update)
        #expect(result.first?.preImage == ["7", "Ada", "2026-01-01"])
        #expect(result.first?.postImage == ["7", "Grace", "2026-01-01"])
        #expect(result.first?.writtenColumns == ["name"])
        #expect(result.first?.isReversible == true)
    }

    @Test("A table with no primary key cannot be restored")
    func noPrimaryKeyIsRefused() {
        let result = operations(
            changes: [cellEdit(column: "name", index: 1, from: "Ada", to: "Grace")],
            primaryKeyColumns: []
        )
        #expect(result.first?.refusal == .noPrimaryKey)
    }

    @Test("A value the server computes leaves no after-image, so the row is refused")
    func serverComputedValueIsRefused() {
        let now = operations(changes: [cellEdit(column: "updated_at", index: 2, from: "2026-01-01", to: "NOW()")])
        #expect(now.first?.refusal == .serverComputedValue)

        let marker = operations(
            changes: [
                cellEdit(
                    column: "updated_at", index: 2, from: "2026-01-01",
                    to: .text(PluginCellValue.defaultMarkerText)
                ),
            ]
        )
        #expect(marker.first?.refusal == .serverComputedValue)
    }

    @Test("A generated column cannot be written back")
    func generatedColumnIsRefused() {
        let result = operations(
            changes: [cellEdit(column: "name", index: 1, from: "Ada", to: "Grace")],
            generatedColumns: ["name"]
        )
        #expect(result.first?.refusal == .serverComputedValue)
    }

    @Test("A value past the capture limit is not kept")
    func oversizedValueIsRefused() {
        let huge = String(repeating: "x", count: RowWriteOperationBuilder.maximumCapturedValueBytes + 1)
        let result = operations(changes: [cellEdit(column: "name", index: 1, from: "Ada", to: .text(huge))])
        #expect(result.first?.refusal == .valueTooLarge)
    }

    @Test("A save that also truncates or drops a table is refused whole")
    func destructiveTableOperationRefusesEveryRow() {
        let result = operations(
            changes: [cellEdit(column: "name", index: 1, from: "Ada", to: "Grace")],
            containsTableOperation: true
        )
        #expect(result.first?.refusal == .destructiveTableOperation)
    }

    @Test("A delete keeps the whole row")
    func deleteCapturesTheRow() {
        let change = RowChange(rowIndex: 0, type: .delete, originalRow: ["7", "Ada", "2026-01-01"])
        let result = operations(changes: [change], deletedRowIndices: [0])

        #expect(result.first?.kind == .delete)
        #expect(result.first?.preImage == ["7", "Ada", "2026-01-01"])
        #expect(result.first?.postImage == nil)
        #expect(result.first?.isReversible == true)
    }

    @Test("An insert whose key the server chooses cannot be taken back")
    func serverAssignedKeyIsRefused() {
        let change = RowChange(rowIndex: 0, type: .insert)
        let withMarker = operations(
            changes: [change],
            insertedRowData: [0: [.text(PluginCellValue.defaultMarkerText), "Ada", "2026-01-01"]],
            insertedRowIndices: [0]
        )
        #expect(withMarker.first?.refusal == .serverAssignedKey)

        let withNull = operations(
            changes: [change],
            insertedRowData: [0: [.null, "Ada", "2026-01-01"]],
            insertedRowIndices: [0]
        )
        #expect(withNull.first?.refusal == .serverAssignedKey)
    }

    @Test("An insert carrying its own key is reversible")
    func userSuppliedKeyIsReversible() {
        let result = operations(
            changes: [RowChange(rowIndex: 0, type: .insert)],
            insertedRowData: [0: ["7", "Ada", "2026-01-01"]],
            insertedRowIndices: [0]
        )
        #expect(result.first?.refusal == nil)
        #expect(result.first?.postImage == ["7", "Ada", "2026-01-01"])
    }
}
