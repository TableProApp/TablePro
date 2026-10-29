//
//  StructureInspectorForm.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One definition's fields as the inspector edits them. Built from the same provider and menus the grid uses, so
// the two never disagree, and written back through the grid's own edit path, one undo step per field.
struct StructureInspectorForm: Equatable {
    struct Field: Equatable, Identifiable {
        enum Kind: Equatable {
            case text
            case multiline
            case toggle
            case menu([GridMenuOption])
            case combo([GridMenuOption])
            case typePicker
        }

        let id: Int
        let label: String
        let value: String?
        let kind: Kind
        let isModified: Bool
        let isEditable: Bool
    }

    let section: StructureSection
    let entityID: UUID
    let name: String
    let fields: [Field]
    let isEditable: Bool
    let isDeleted: Bool
    let isNew: Bool

    @MainActor
    static func build(adapter: StructureSectionAdapter, sourceIndex: Int, entityID: UUID) -> StructureInspectorForm? {
        let provider = StructureRowProvider(
            changeManager: adapter.manager,
            tab: adapter.section,
            databaseType: adapter.context.databaseType,
            additionalFields: [.primaryKey],
            serverSupport: adapter.serverSupport,
            picksCharacterSets: ColumnCharacterSetMenus.offersMenus(adapter.characterSetContext.catalog)
        )
        guard let values = provider.row(at: sourceIndex) else { return nil }
        let names = provider.columns
        let state = adapter.manager.deleteInsertState(for: sourceIndex, tab: adapter.section)
        let modified = provider.modifiedFieldIndices(atDisplay: sourceIndex)
        let locked = adapter.lockedFieldIndices.union(adapter.characterSetLockedFields(sourceIndex: sourceIndex))
        let isEditable = adapter.canEdit && !state.isDeleted
        let fields = names.indices.map { index in
            Field(
                id: index,
                label: names[index],
                value: index < values.count ? values[index] : nil,
                kind: kind(
                    at: index,
                    section: adapter.section,
                    orderedFields: provider.orderedColumnFields,
                    options: adapter.menuOptions(sourceIndex: sourceIndex, field: index) ?? provider.customDropdownOptions[index],
                    typePickerColumns: provider.typePickerColumns
                ),
                isModified: !state.isInserted && modified.contains(index),
                isEditable: isEditable && !locked.contains(index)
            )
        }
        return StructureInspectorForm(
            section: adapter.section,
            entityID: entityID,
            name: (values.first ?? nil) ?? "",
            fields: fields,
            isEditable: isEditable,
            isDeleted: state.isDeleted,
            isNew: state.isInserted
        )
    }

    @MainActor
    static func kind(
        at index: Int,
        section: StructureSection,
        orderedFields: [StructureColumnField],
        options: [GridMenuOption]?,
        typePickerColumns: Set<Int>
    ) -> Field.Kind {
        if typePickerColumns.contains(index) {
            return .typePicker
        }
        if let options, !options.isEmpty {
            if options.compactMap(\.sql) == StructureRowProvider.booleanOptions {
                return .toggle
            }
            if options.contains(where: { if case .custom = $0 { true } else { false } }) {
                return .combo(options)
            }
            return .menu(options)
        }
        switch section {
        case .columns:
            guard orderedFields.indices.contains(index) else { return .text }
            switch orderedFields[index] {
            case .comment, .generationExpression: return .multiline
            default: return .text
            }
        case .checkConstraints:
            return index == 1 ? .multiline : .text
        case .indexes:
            return index == 4 ? .multiline : .text
        case .foreignKeys:
            return .text
        }
    }
}
