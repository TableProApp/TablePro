//
//  StructureGridDelegate+Inspector.swift
//  TablePro
//
//  Supplies the right inspector with the selected structure row and routes
//  its edits back through the same commit path as an inline grid edit.
//

import Foundation

extension StructureGridDelegate: InspectorRowSource {
    func inspectorRow(atDisplayRow displayRow: Int) -> InspectorRow? {
        guard let provider = currentProvider else { return nil }
        return StructureInspectorRowBuilder.row(
            atDisplayRow: displayRow,
            tab: selectedTab,
            provider: provider,
            canEditSchema: connection.type.supportsSchemaEditing
        )
    }

    func commitInspectorField(displayRow: Int, fieldIndex: Int, value: String?) {
        dataGridDidEditCell(row: displayRow, column: fieldIndex, newValue: value)
    }
}
