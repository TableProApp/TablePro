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
        guard let plugin = PluginManager.shared.exportPlugins[formatId] else { return [] }
        return type(of: plugin).perTableOptionColumns
    }

    private var currentPlugin: (any ExportFormatPlugin)? {
        PluginManager.shared.exportPlugins[formatId]
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
                        allTables[index].isSelected.wrappedValue = newState
                        if newState && !optionColumns.isEmpty {
                            if allTables[index].wrappedValue.optionValues.isEmpty ||
                                !allTables[index].wrappedValue.optionValues.contains(true) {
                                let defaults = currentPlugin?.defaultTableOptionValues() ?? Array(repeating: true, count: optionColumns.count)
                                allTables[index].optionValues.wrappedValue = defaults
                            }
                        }
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
                            guard colIndex < table.wrappedValue.optionValues.count else { return true }
                            return table.optionValues[colIndex].wrappedValue
                        },
                        set: { newValue in
                            ensureOptionValues(table)
                            table.optionValues[colIndex].wrappedValue = newValue
                            let anyTrue = table.wrappedValue.optionValues.contains(true)
                            table.isSelected.wrappedValue = anyTrue
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
        if !table.isSelected || table.optionValues.isEmpty { return .unchecked }
        let trueCount = table.optionValues.count(where: { $0 })
        if trueCount == 0 { return .unchecked }
        if trueCount == table.optionValues.count { return .checked }
        return .mixed
    }

    private func toggleGenericOptions(_ table: Binding<ExportTableItem>) {
        ensureOptionValues(table)
        if !table.wrappedValue.isSelected {
            table.isSelected.wrappedValue = true
            if !table.wrappedValue.optionValues.contains(true) {
                for i in table.wrappedValue.optionValues.indices {
                    table.optionValues[i].wrappedValue = true
                }
            }
        } else {
            let allChecked = table.wrappedValue.optionValues.allSatisfy { $0 }
            if allChecked {
                table.isSelected.wrappedValue = false
            } else {
                for i in table.wrappedValue.optionValues.indices {
                    table.optionValues[i].wrappedValue = true
                }
            }
        }
    }

    private func ensureOptionValues(_ table: Binding<ExportTableItem>) {
        if table.wrappedValue.optionValues.count < optionColumns.count {
            let defaults = currentPlugin?.defaultTableOptionValues() ?? Array(repeating: true, count: optionColumns.count)
            table.optionValues.wrappedValue = defaults
        }
    }
}

// MARK: - Tristate Checkbox

/// Native macOS tristate checkbox using NSButton
private struct TristateCheckbox: NSViewRepresentable {
    enum State {
        case unchecked, checked, mixed
    }

    let state: State
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        switch state {
        case .unchecked: button.state = .off
        case .checked: button.state = .on
        case .mixed: button.state = .mixed
        }
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }
        @objc func clicked() {
            action()
        }
    }
}
