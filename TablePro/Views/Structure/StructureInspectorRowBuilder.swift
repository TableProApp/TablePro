//
//  StructureInspectorRowBuilder.swift
//  TablePro
//
//  Builds the inspector payload for a structure grid row. Field names, values,
//  and editors all come from the same provider the grid renders, so the panel
//  and the grid can never disagree about what a row holds.
//

import Foundation

@MainActor
internal enum StructureInspectorRowBuilder {
    static func row(
        atDisplayRow displayRow: Int,
        tab: StructureTab,
        provider: StructureRowProvider,
        canEditSchema: Bool
    ) -> InspectorRow? {
        switch tab {
        case .columns, .indexes, .foreignKeys:
            break
        case .ddl, .parts, .triggers:
            return nil
        }

        guard let values = provider.row(at: displayRow) else { return nil }

        let names = provider.columns
        let dropdownOptions = provider.customDropdownOptions
        let typePickerColumns = provider.typePickerColumns
        let modified = provider.modifiedFieldIndices(atDisplay: displayRow)

        let fields = names.indices.map { index -> InspectorRowField in
            InspectorRowField(
                name: names[index],
                value: index < values.count ? values[index] : nil,
                editor: editor(
                    at: index,
                    dropdownOptions: dropdownOptions,
                    typePickerColumns: typePickerColumns
                ),
                isModified: modified.contains(index)
            )
        }

        return InspectorRow(
            fields: fields,
            isEditable: canEditSchema && !provider.isPendingDelete(atDisplay: displayRow)
        )
    }

    private static func editor(
        at index: Int,
        dropdownOptions: [Int: [String]],
        typePickerColumns: Set<Int>
    ) -> FieldEditorKind {
        if let options = dropdownOptions[index], !options.isEmpty {
            return .enumPicker(values: options)
        }
        if typePickerColumns.contains(index) {
            return .typePicker
        }
        return .schemaText
    }
}
