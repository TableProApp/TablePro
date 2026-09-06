//
//  SidebarContextMenu.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

enum SidebarContextMenuLogic {
    static func isView(clickedTable: TableInfo?) -> Bool {
        clickedTable?.type == .view
    }

    static func isReadOnlyKind(_ type: TableInfo.TableType?) -> Bool {
        TableOperationEligibility.isReadOnlyKind(type)
    }

    static func importVisible(clickedTable: TableInfo?, supportsImport: Bool) -> Bool {
        guard supportsImport else { return false }
        return !isReadOnlyKind(clickedTable?.type)
    }

    /// Asked of every row the command would act on, not just the one under the pointer. Right
    /// clicking a table inside a selection that also held a view offered Truncate and staged it
    /// for the view as well.
    static func truncateVisible(targets: some Collection<DatabaseTreeTableRef>) -> Bool {
        TableOperationEligibility.canTruncate(targets)
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
