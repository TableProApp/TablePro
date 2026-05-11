//
//  SidebarContextMenu.swift
//  TablePro
//
//  Context menu for sidebar table rows and empty space.
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

    /// True when the object cannot be modified via DML (INSERT/UPDATE/DELETE).
    static func isReadOnlyKind(_ type: TableInfo.TableType?) -> Bool {
        switch type {
        case .view, .materializedView, .foreignTable, .systemTable:
            return true
        case .table, .none:
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
        case .table, .none:     return String(localized: "Delete")
        }
    }
}

/// Unified context menu for sidebar — used for both table rows and empty space
struct SidebarContextMenu: View {
    let clickedTable: TableInfo?
    let selectedTables: Set<TableInfo>
    let isReadOnly: Bool
    let onBatchToggleTruncate: ([String]) -> Void
    let onBatchToggleDelete: ([String]) -> Void
    let coordinator: MainContentCoordinator?

    private var hasSelection: Bool {
        SidebarContextMenuLogic.hasSelection(selectedTables: selectedTables, clickedTable: clickedTable)
    }

    private var isView: Bool {
        SidebarContextMenuLogic.isView(clickedTable: clickedTable)
    }

    private var effectiveTableNames: [String] {
        if selectedTables.isEmpty, let table = clickedTable {
            return [table.name]
        }
        return selectedTables.map(\.name).sorted()
    }

    var body: some View {
        Button("Create New Table...") {
            coordinator?.createNewTable()
        }
        .disabled(isReadOnly)

        Button("Create New View...") {
            coordinator?.createView()
        }
        .disabled(isReadOnly)

        Divider()

        if isView {
            Button("Edit View Definition") {
                if let viewName = clickedTable?.name {
                    coordinator?.editViewDefinition(viewName)
                }
            }
            .disabled(isReadOnly)
        }

        Button("Show Structure") {
            if let tableName = clickedTable?.name {
                coordinator?.openTableTab(tableName, showStructure: true)
            }
        }
        .disabled(clickedTable == nil)

        Button(String(localized: "View ER Diagram")) {
            coordinator?.showERDiagram()
        }

        Button("Copy Name") {
            ClipboardService.shared.writeText(effectiveTableNames.joined(separator: ","))
        }
        .disabled(!hasSelection)

        Button("Export...") {
            coordinator?.openExportDialog(preselectedTableNames: Set(effectiveTableNames))
        }
        .disabled(!hasSelection)

        if SidebarContextMenuLogic.importVisible(
            clickedTable: clickedTable,
            supportsImport: PluginManager.shared.supportsImport(
                for: coordinator?.connection.type ?? .mysql
            )
        ) {
            Button("Import...") {
                coordinator?.openImportDialog()
            }
            .disabled(isReadOnly)
        }

        if let ops = coordinator?.supportedMaintenanceOperations(), !ops.isEmpty, hasSelection {
            Menu(String(localized: "Maintenance")) {
                ForEach(ops, id: \.self) { op in
                    Button(op) {
                        if let table = clickedTable?.name {
                            coordinator?.showMaintenanceSheet(operation: op, tableName: table)
                        }
                    }
                }
            }
            .disabled(isReadOnly)
        }

        Divider()

        if SidebarContextMenuLogic.truncateVisible(clickedTable: clickedTable) {
            Button("Truncate") {
                onBatchToggleTruncate(effectiveTableNames)
            }
            .disabled(!hasSelection || isReadOnly)
        }

        Button(
            SidebarContextMenuLogic.deleteLabel(for: clickedTable?.type),
            role: .destructive
        ) {
            onBatchToggleDelete(effectiveTableNames)
        }
        .disabled(!hasSelection || isReadOnly)
    }
}
