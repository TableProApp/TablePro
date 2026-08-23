//
//  SidebarContextMenu.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

enum SidebarContextMenuLogic {
    static func hasSelection(selectedTables: Set<TableInfo>, clickedTable: TableInfo?) -> Bool {
        !selectedTables.isEmpty || clickedTable != nil
    }

    static func isView(clickedTable: TableInfo?) -> Bool {
        clickedTable?.type == .view
    }

    /// AppKit's rule for a contextual menu over a list: a click inside the selection acts on the
    /// whole selection, a click outside it acts on the row under the pointer and nothing else.
    static func contextTargets(clickedTable: TableInfo?, selectedTables: Set<TableInfo>) -> [String] {
        guard let clickedTable else { return selectedTables.map(\.name).sorted() }
        guard selectedTables.contains(clickedTable) else { return [clickedTable.name] }
        return selectedTables.map(\.name).sorted()
    }

    static func isReadOnlyKind(_ type: TableInfo.TableType?) -> Bool {
        switch type {
        case .view, .materializedView, .foreignTable, .systemTable, .externalTable:
            return true
        case .table, .partitionedTable, .none:
            return false
        }
    }

    static func importVisible(clickedTable: TableInfo?, supportsImport: Bool) -> Bool {
        guard supportsImport else { return false }
        return !isReadOnlyKind(clickedTable?.type)
    }

    static func truncateVisible(clickedTable: TableInfo?) -> Bool {
        !isReadOnlyKind(clickedTable?.type)
    }

    static func deleteLabel(for type: TableInfo.TableType?) -> String {
        switch type {
        case .view:             return String(localized: "Drop View")
        case .materializedView: return String(localized: "Drop Materialized View")
        case .foreignTable:     return String(localized: "Drop Foreign Table")
        case .systemTable:      return String(localized: "Drop")
        case .externalTable:    return String(localized: "Drop External Table")
        case .table, .partitionedTable, .none: return String(localized: "Delete")
        }
    }

    static func maintenanceGroupEnabled(
        isReadOnly: Bool,
        hasSelection: Bool,
        supportedOperations: [String]
    ) -> Bool {
        guard !isReadOnly, hasSelection else { return false }
        return !supportedOperations.isEmpty
    }
}
