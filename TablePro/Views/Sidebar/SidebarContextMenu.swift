//
//  SidebarContextMenu.swift
//  TablePro
//
//  Context menu for sidebar table rows and empty space.
//

import SwiftUI
import TableProPluginKit

/// Extracted logic from SidebarContextMenu for testability
enum SidebarContextMenuLogic {
    static func hasSelection(selectedTables: Set<TableInfo>, clickedTable: TableInfo?) -> Bool {
        !selectedTables.isEmpty || clickedTable != nil
    }

    static func isView(clickedTable: TableInfo?) -> Bool {
        clickedTable?.type == .view
    }

    static func importVisible(isView: Bool, supportsImport: Bool) -> Bool {
        !isView && supportsImport
    }

    static func truncateVisible(isView: Bool) -> Bool {
        !isView
    }

    static func deleteLabel(isView: Bool) -> String {
        isView ? String(localized: "Drop View") : String(localized: "Delete")
    }
}

/// Unified context menu for sidebar — used for both table rows and empty space
struct SidebarContextMenu: View {
    let clickedTable: TableInfo?
    @Binding var selectedTables: Set<TableInfo>
    let isReadOnly: Bool
    let onBatchToggleTruncate: () -> Void
    let onBatchToggleDelete: () -> Void
    let coordinator: MainContentCoordinator?

    private var hasSelection: Bool {
        SidebarContextMenuLogic.hasSelection(selectedTables: selectedTables, clickedTable: clickedTable)
    }

    private var isView: Bool {
        SidebarContextMenuLogic.isView(clickedTable: clickedTable)
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
            let names: [String]
            if selectedTables.isEmpty, let table = clickedTable {
                names = [table.name]
            } else {
                names = selectedTables.map { $0.name }.sorted()
            }
            ClipboardService.shared.writeText(names.joined(separator: ","))
        }
        .disabled(!hasSelection)

        Button("Export...") {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            coordinator?.openExportDialog()
        }
        .disabled(!hasSelection)

        if SidebarContextMenuLogic.importVisible(
            isView: isView,
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

        if !isView {
            Button("Truncate") {
                if selectedTables.isEmpty, let table = clickedTable {
                    selectedTables.insert(table)
                }
                onBatchToggleTruncate()
            }
            .disabled(!hasSelection || isReadOnly)
        }

        Button(
            isView ? String(localized: "Drop View") : String(localized: "Delete"),
            role: .destructive
        ) {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            onBatchToggleDelete()
        }
        .disabled(!hasSelection || isReadOnly)
    }
}
