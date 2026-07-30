//
//  CreateTableGridDelegate+Inspector.swift
//  TablePro
//
//  Supplies the right inspector with the selected new-table row and routes
//  its edits back through the same commit path as an inline grid edit.
//

import Foundation
import TableProPluginKit

extension CreateTableGridDelegate: InspectorRowSource {
    func inspectorRow(atDisplayRow displayRow: Int) -> InspectorRow? {
        StructureInspectorRowBuilder.row(
            atDisplayRow: displayRow,
            tab: structureTab,
            provider: StructureRowProvider(
                changeManager: structureChangeManager,
                tab: structureTab,
                databaseType: connection.type,
                additionalFields: [.primaryKey]
            ),
            canEditSchema: true
        )
    }

    func commitInspectorField(displayRow: Int, fieldIndex: Int, value: String?) {
        dataGridDidEditCell(row: displayRow, column: fieldIndex, newValue: value)
    }
}
