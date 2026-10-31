//
//  ColumnCharacterSetMenus.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The Charset and Collation cells of the Structure and Create Table grids: their menus, the names they
// take and when they are read-only. The server refuses a name it does not know (ERROR 1253, unknown
// character set), so once the catalog is read the list is closed and a typed name must be in it.
enum ColumnCharacterSetMenus {
    struct Context {
        var catalog: MetadataLoadState<TableOptionsCatalog?>
        // What a column without a character set of its own takes.
        var tableCharacterSet: String?

        var loadedCatalog: TableOptionsCatalog? {
            guard case .loaded(let catalog) = self.catalog else { return nil }
            return catalog
        }
    }

    enum Entry: Equatable {
        // The engine has no catalog, so the text is written as typed.
        case unchecked
        case unchanged
        case set(characterSet: String?, collation: String?)
        case refused
    }

    static func isCharacterSetField(_ field: StructureColumnField) -> Bool {
        field == .charset || field == .collation
    }

    // An engine whose driver has no catalog keeps the plain text cell it always had.
    static func offersMenus(_ catalog: MetadataLoadState<TableOptionsCatalog?>) -> Bool {
        if case .loaded(.none) = catalog { return false }
        return true
    }

    static func options(
        for field: StructureColumnField,
        column: EditableColumnDefinition,
        context: Context
    ) -> [GridMenuOption]? {
        guard isCharacterSetField(field), takesCharacterSet(column) else { return nil }
        let current = field == .charset ? column.charset : column.collation
        switch context.catalog {
        case .loaded(.none):
            return nil
        case .idle, .loading:
            return [.sectionHeader(String(localized: "Loading…"))] + currentOnly(current)
        case .failed:
            return [.sectionHeader(String(localized: "Couldn't read the character sets"))] + currentOnly(current)
        case .loaded(.some(let catalog)):
            if field == .charset {
                return characterSetOptions(catalog: catalog, current: current)
            }
            return collationOptions(
                catalog: catalog,
                characterSet: column.charset ?? context.tableCharacterSet,
                current: current
            )
        }
    }

    static func entry(
        _ text: String,
        for field: StructureColumnField,
        column: EditableColumnDefinition,
        context: Context
    ) -> Entry {
        guard isCharacterSetField(field) else { return .unchecked }
        let name = text.trimmingCharacters(in: .whitespaces)
        switch context.catalog {
        case .loaded(.none):
            return .unchecked
        case .idle, .loading, .failed:
            return .refused
        case .loaded(.some(let catalog)):
            if name.isEmpty {
                return clearing(field, column: column)
            }
            guard takesCharacterSet(column) else { return .refused }
            if field == .charset {
                return characterSetEntry(name, column: column, catalog: catalog)
            }
            return collationEntry(name, column: column, catalog: catalog)
        }
    }

    static func locks(
        _ field: StructureColumnField,
        column: EditableColumnDefinition,
        catalog: MetadataLoadState<TableOptionsCatalog?>
    ) -> Bool {
        guard isCharacterSetField(field) else { return false }
        switch catalog {
        case .loaded(.none):
            return false
        case .loaded(.some):
            return !takesCharacterSet(column)
        case .idle, .loading, .failed:
            return true
        }
    }

    static func lockedFieldIndices(
        orderedFields: [StructureColumnField],
        column: EditableColumnDefinition,
        catalog: MetadataLoadState<TableOptionsCatalog?>
    ) -> Set<Int> {
        Set(orderedFields.indices.filter { locks(orderedFields[$0], column: column, catalog: catalog) })
    }

    // MARK: - Menus

    private static func characterSetOptions(catalog: TableOptionsCatalog, current: String?) -> [GridMenuOption] {
        var options: [GridMenuOption] = [.value(title: String(localized: "Table Default"), sql: "")]
        let names = catalog.characterSets.map(\.name)
        if let current, !current.isEmpty, !names.contains(where: { matches($0, current) }) {
            options.append(.value(title: current, sql: current))
        }
        options += GridMenuOption.values(names)
        return options
    }

    private static func collationOptions(
        catalog: TableOptionsCatalog,
        characterSet: String?,
        current: String?
    ) -> [GridMenuOption] {
        guard let characterSet = characterSet.flatMap({ catalog.characterSet(named: $0) }) else {
            return [.sectionHeader(String(localized: "Choose a character set first"))] + currentOnly(current)
        }
        var options: [GridMenuOption] = [.sectionHeader(characterSet.name)]
        if let current, !current.isEmpty, !characterSet.collations.contains(where: { matches($0, current) }) {
            options.append(.value(title: current, sql: current))
        }
        options += characterSet.collations.map { name in
            GridMenuOption.value(
                title: TableOptionsForm.collationTitle(name, isDefault: name == characterSet.defaultCollation),
                sql: name
            )
        }
        return options
    }

    private static func currentOnly(_ current: String?) -> [GridMenuOption] {
        guard let current, !current.isEmpty else { return [] }
        return [.value(title: current, sql: current)]
    }

    // MARK: - Entries

    private static func clearing(_ field: StructureColumnField, column: EditableColumnDefinition) -> Entry {
        if field == .charset {
            return column.charset == nil && column.collation == nil ? .unchanged : .set(characterSet: nil, collation: nil)
        }
        return column.collation == nil ? .unchanged : .set(characterSet: column.charset, collation: nil)
    }

    private static func characterSetEntry(
        _ name: String,
        column: EditableColumnDefinition,
        catalog: TableOptionsCatalog
    ) -> Entry {
        guard let characterSet = catalog.characterSet(named: name) else {
            return matches(name, column.charset) ? .unchanged : .refused
        }
        guard !matches(characterSet.name, column.charset) else { return .unchanged }
        return .set(characterSet: characterSet.name, collation: characterSet.defaultCollation.nilIfEmpty)
    }

    // A collation belongs to one character set, so a name from another set moves the column to that set.
    private static func collationEntry(
        _ name: String,
        column: EditableColumnDefinition,
        catalog: TableOptionsCatalog
    ) -> Entry {
        guard !matches(name, column.collation) else { return .unchanged }
        guard let owner = catalog.characterSet(owning: name),
              let collation = owner.collations.first(where: { matches($0, name) }) else { return .refused }
        return .set(characterSet: owner.name, collation: collation)
    }

    // MARK: - Helpers

    private static func takesCharacterSet(_ column: EditableColumnDefinition) -> Bool {
        ColumnTextType.takesCharacterSet(column.dataType)
    }

    private static func matches(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
