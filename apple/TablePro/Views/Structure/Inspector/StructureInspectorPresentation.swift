//
//  StructureInspectorPresentation.swift
//  TablePro
//

import Foundation

enum StructureInspectorPresentation {
    @MainActor
    static func subject(
        for target: StructureDefinitionEditor.InspectorTarget,
        definitionName: String?,
        tableName: String
    ) -> InspectorSubject {
        let table = tableName.isEmpty ? nil : tableName
        switch target {
        case .entity(let section, _):
            return .definition(name: definitionName ?? "", section: section, table: table)
        case .table, .several:
            return .tableOnly(table: table ?? String(localized: "New Table"))
        }
    }

    static func severalTitle(_ section: StructureSection, count: Int) -> String {
        switch section {
        case .columns: String(format: String(localized: "%d Columns Selected"), count)
        case .indexes: String(format: String(localized: "%d Indexes Selected"), count)
        case .foreignKeys: String(format: String(localized: "%d Foreign Keys Selected"), count)
        case .checkConstraints: String(format: String(localized: "%d Check Constraints Selected"), count)
        }
    }

    static func controlIdentifier(section: StructureSection, field: Int) -> String {
        "structure-inspector-\(section.rawValue)-\(field)"
    }
}

// The control a definition field gets in the inspector. A field the form cannot edit is plain text.
enum StructureInspectorControl: Equatable {
    case text
    case multiline
    case checkbox
    case popUp(StructureInspectorChoices)
    case comboBox(StructureInspectorChoices)
    case typePicker
    case readOnly(String)

    static func resolve(_ field: StructureInspectorForm.Field) -> StructureInspectorControl {
        let value = field.value ?? ""
        switch field.kind {
        case .text:
            return field.isEditable ? .text : .readOnly(value)
        case .multiline:
            return field.isEditable ? .multiline : .readOnly(value)
        case .toggle:
            return field.isEditable ? .checkbox : .readOnly(value)
        case .typePicker:
            return field.isEditable ? .typePicker : .readOnly(value)
        case .menu(let options):
            let choices = StructureInspectorChoices(options: options, current: value)
            return field.isEditable ? .popUp(choices) : .readOnly(choices.selectedTitle ?? value)
        case .combo(let options):
            return field.isEditable ? .comboBox(StructureInspectorChoices(options: options, current: value)) : .readOnly(value)
        }
    }
}

// A grid menu as a pop-up button's items. The value a field holds is always an item, listed or not, since a pop-up
// whose selection matches no tag shows nothing selected.
struct StructureInspectorChoices: Equatable {
    struct Item: Equatable, Identifiable {
        let id: Int
        let title: String
        let value: String
    }

    struct ItemGroup: Equatable, Identifiable {
        let id: Int
        let header: String?
        var items: [Item]
    }

    let groups: [ItemGroup]
    let selectedID: Int?

    var items: [Item] { groups.flatMap(\.items) }

    var selectedTitle: String? {
        items.first { $0.id == selectedID }?.title
    }

    func value(of id: Int) -> String? {
        items.first { $0.id == id }?.value
    }

    init(options: [GridMenuOption], current: String) {
        var groups = [ItemGroup(id: options.count + 1, header: nil, items: [])]
        for (index, option) in options.enumerated() {
            switch option {
            case .sectionHeader(let title):
                groups.append(ItemGroup(id: index, header: title, items: []))
            case .value(let title, let sql):
                groups[groups.count - 1].items.append(Item(id: index, title: title, value: sql))
            case .clear(let title):
                groups[groups.count - 1].items.append(Item(id: index, title: title, value: ""))
            case .custom:
                continue
            }
        }
        let listed = groups.flatMap(\.items)
        var selected = listed.first { $0.value == current }?.id
            ?? listed.first { $0.value.caseInsensitiveCompare(current) == .orderedSame }?.id
        if selected == nil, !current.isEmpty {
            let kept = Item(id: options.count, title: current, value: current)
            groups[0].items.insert(kept, at: 0)
            selected = kept.id
        }
        self.groups = groups.filter { $0.header != nil || !$0.items.isEmpty }
        selectedID = selected
    }
}
