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

struct SidebarContextMenu: View {
    let clickedTable: TableInfo?
    let selectedTables: Set<TableInfo>
    let isReadOnly: Bool
    let onBatchToggleTruncate: ([String]) -> Void
    let onBatchToggleDelete: ([String]) -> Void
    let coordinator: MainContentCoordinator?
    var activateBeforeAction: (@MainActor () async -> Void)?

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

    @MainActor
    private func perform(_ action: @MainActor @escaping () -> Void) {
        guard let activate = activateBeforeAction else {
            action()
            return
        }
        Task { @MainActor in
            await activate()
            action()
        }
    }

    var body: some View {
        Button("Create New Table...") {
            perform { coordinator?.createNewTable() }
        }
        .disabled(isReadOnly)

        Button("Create New View...") {
            perform { coordinator?.createView() }
        }
        .disabled(isReadOnly)

        Divider()

        if clickedTable != nil {
            if isView {
                Button("Edit View Definition") {
                    perform {
                        if let viewName = clickedTable?.name {
                            coordinator?.editViewDefinition(viewName)
                        }
                    }
                }
                .disabled(isReadOnly)
            }

            Button("Show Structure") {
                perform {
                    if let clickedTable {
                        coordinator?.openTableTab(clickedTable, showStructure: true)
                    }
                }
            }
        }

        Button("View ER Diagram") {
            perform { coordinator?.showERDiagram() }
        }

        if hasSelection {
            Button("Copy Name") {
                ClipboardService.shared.writeText(effectiveTableNames.joined(separator: ","))
            }

            Button("Export...") {
                perform { coordinator?.openExportDialog(preselectedTableNames: Set(effectiveTableNames)) }
            }
        }

        if SidebarContextMenuLogic.importVisible(
            clickedTable: clickedTable,
            supportsImport: PluginManager.shared.supportsImport(
                for: coordinator?.connection.type ?? .mysql
            )
        ) {
            Button("Import...") {
                perform { coordinator?.openImportDialog() }
            }
            .disabled(isReadOnly)
        }

        if hasSelection,
           let ops = coordinator?.supportedMaintenanceOperations(), !ops.isEmpty {
            Menu(String(localized: "Maintenance")) {
                ForEach(ops, id: \.self) { op in
                    Button(op) {
                        perform {
                            if let table = clickedTable?.name {
                                coordinator?.showMaintenanceSheet(operation: op, tableName: table)
                            }
                        }
                    }
                }
            }
            .disabled(isReadOnly)
        }

        if hasSelection {
            Divider()

            if SidebarContextMenuLogic.truncateVisible(clickedTable: clickedTable) {
                Button("Truncate") {
                    perform { onBatchToggleTruncate(effectiveTableNames) }
                }
                .disabled(isReadOnly)
            }

            Button(
                SidebarContextMenuLogic.deleteLabel(for: clickedTable?.type),
                role: .destructive
            ) {
                perform { onBatchToggleDelete(effectiveTableNames) }
            }
            .disabled(isReadOnly)
        }
    }
}
