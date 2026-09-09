//
//  CreateTableGridDelegate+References.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The Foreign Keys grid's three reference cells offer what the database actually holds.
///
/// They were free text, so the only way to point a key at a table was to spell its name and its
/// columns from memory, and a typo produced a server error at Create time rather than a list that
/// could not be wrong. `StructureGridDelegate` answers the same question for an existing table, and
/// both go through `ForeignKeyReferenceMenus` so the two grids cannot drift.
extension CreateTableGridDelegate {
    func dataGridMenuOptions(forRow row: Int, columnIndex: Int) -> [GridMenuOption]? {
        guard structureTab == .foreignKeys,
              row >= 0, row < structureChangeManager.workingForeignKeys.count else { return nil }
        return referenceMenus.options(
            columnIndex: columnIndex,
            foreignKey: structureChangeManager.workingForeignKeys[row],
            tableColumns: structureChangeManager.workingColumns.map(\.name)
        )
    }
}
