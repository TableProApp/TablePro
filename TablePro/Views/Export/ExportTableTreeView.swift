//
//  ExportTableTreeView.swift
//  TablePro
//
//  Pure SwiftUI tree view for selecting tables in the export dialog.
//  Replaces the NSOutlineView-based ExportTableOutlineView.
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ExportTableTreeView: View {
    @Binding var databaseItems: [ExportDatabaseItem]
    let formatId: String

    private var optionColumns: [PluginExportOptionColumn] {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: formatId) else { return [] }
        return type(of: plugin).perTableOptionColumns
    }

    private var currentPlugin: (any ExportFormatPlugin)? {
        PluginManager.shared.exportPlugin(forFormat: formatId)
    }

    private var defaultOptionValues: [Bool] {
        currentPlugin?.defaultTableOptionValues() ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(databaseItems) { database in
                    let databaseBinding = $databaseItems.element(database)
                    DisclosureGroup(isExpanded: databaseBinding.isExpanded) {
                        ForEach(database.tables) { table in
                            let tableBinding = databaseBinding.tables.element(table)
                            tableRow(table: tableBinding)
                        }
                    } label: {
                        databaseLabel(database: database, allTables: databaseBinding.tables)
                    }
                }
            }
            .listStyle(.plain)
            .alternatingRowBackgrounds(.enabled)
        }
    }

    // MARK: - Database Row

    private func databaseLabel(
        database: ExportDatabaseItem,
        allTables: Binding<[ExportTableItem]>
    ) -> some View {
        HStack(spacing: 4) {
            TristateCheckbox(
                state: databaseCheckboxState(database),
                action: {
                    let newState = !database.allSelected
                    for index in allTables.wrappedValue.indices {
                        var updated = allTables[index].wrappedValue
                        updated.isSelected = newState
                        if newState {
                            updated = updated.normalized(
                                forOptionColumnCount: optionColumns.count,
                                defaultOptionValues: defaultOptionValues
                            )
                        }
                        allTables[index].wrappedValue = updated
                    }
                }
            )
            .disabled(database.tables.isEmpty)
            .frame(width: 18)

            Image(systemName: "cylinder")
                .foregroundStyle(.blue)
                .font(.body)

            Text(database.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func databaseCheckboxState(_ database: ExportDatabaseItem) -> TristateCheckbox.State {
        let selected = database.selectedCount
        if selected == 0 { return .unchecked }
        if selected == database.tables.count { return .checked }
        return .mixed
    }

    // MARK: - Table Row

    private func tableRow(table: Binding<ExportTableItem>) -> some View {
        HStack(spacing: 4) {
            if !optionColumns.isEmpty {
                TristateCheckbox(
                    state: genericCheckboxState(table.wrappedValue),
                    action: {
                        toggleGenericOptions(table)
                    }
                )
                .frame(width: 18)
            } else {
                Toggle("", isOn: table.isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }

            Image(systemName: table.wrappedValue.type == .view ? "eye" : "tablecells")
                .foregroundStyle(table.wrappedValue.type == .view ? .purple : .gray)
                .font(.body)

            Text(table.wrappedValue.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            if !optionColumns.isEmpty {
                Spacer()

                ForEach(Array(optionColumns.enumerated()), id: \.element.id) { colIndex, column in
                    Toggle(column.label, isOn: Binding(
                        get: {
                            table.wrappedValue.optionValues[safe: colIndex] ?? column.defaultValue
                        },
                        set: { newValue in
                            guard table.wrappedValue.optionValues.indices.contains(colIndex) else { return }
                            table.optionValues[colIndex].wrappedValue = newValue
                            table.isSelected.wrappedValue = table.wrappedValue.optionValues.contains(true)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!table.wrappedValue.isSelected)
                    .opacity(table.wrappedValue.isSelected ? 1.0 : 0.4)
                    .frame(width: column.width, alignment: .center)
                }
            }
        }
    }

    // MARK: - Generic Option Helpers

    private func genericCheckboxState(_ table: ExportTableItem) -> TristateCheckbox.State {
        if !table.isSelected { return .unchecked }
        let trueCount = table.optionValues.count(where: { $0 })
        if trueCount == 0 { return .unchecked }
        if trueCount == table.optionValues.count { return .checked }
        return .mixed
    }

    private func toggleGenericOptions(_ table: Binding<ExportTableItem>) {
        guard table.wrappedValue.isSelected else {
            var updated = table.wrappedValue
            updated.isSelected = true
            table.wrappedValue = updated.normalized(
                forOptionColumnCount: optionColumns.count,
                defaultOptionValues: defaultOptionValues
            )
            return
        }
        if table.wrappedValue.optionValues.allSatisfy({ $0 }) {
            table.isSelected.wrappedValue = false
        } else {
            table.optionValues.wrappedValue = Array(repeating: true, count: optionColumns.count)
        }
    }
}
