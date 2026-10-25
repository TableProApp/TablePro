//
//  StructureGridAdapter+Inspector.swift
//  TablePro
//

import Foundation

// The inspector names a row by its position in the grid, the same position the grid's selection uses.
extension StructureGridAdapter: InspectorRowSource {
    func inspectorRow(atDisplayRow displayRow: Int) -> InspectorRow? {
        guard let rowID = model.rowID(at: displayRow),
              let sourceIndex = StructureRowProvider.sourceIndex(of: rowID),
              let providerRow = provider.displayRow(ofSourceIndex: sourceIndex) else { return nil }
        return StructureInspectorRowBuilder.row(
            atDisplayRow: providerRow,
            tab: selectedTab,
            provider: provider,
            canEditSchema: canEdit,
            lockedFieldIndices: lockedFieldIndices,
            rowOptions: { menuOptions(sourceIndex: sourceIndex, field: $0) }
        )
    }

    func commitInspectorField(displayRow: Int, fieldIndex: Int, value: String?) {
        guard let rowID = model.rowID(at: displayRow) else { return }
        applyEdit(rowID: rowID, field: fieldIndex, text: value ?? "")
    }
}
