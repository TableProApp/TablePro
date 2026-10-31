//
//  InspectorSubject.swift
//  TablePro
//

import Foundation

// What the inspector is inspecting, as the two lines it draws above its content. A structure definition has no
// position in a result, so it is named by what it is and whose it is, never "Row 0 of 0".
internal enum InspectorSubject: Equatable {
    case empty
    case tableRow(table: String, position: RowPosition?)
    case multipleRows(table: String, count: Int)
    case definition(name: String, section: StructureSection, table: String?)
    case tableOnly(table: String)

    internal struct RowPosition: Equatable {
        internal let index: Int
        internal let total: Int

        internal init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    internal var title: String? {
        switch self {
        case .empty:
            return nil
        case .tableRow(let table, _), .multipleRows(let table, _), .tableOnly(let table):
            return table
        case .definition(let name, let section, _):
            return name.isEmpty ? Self.newDefinitionTitle(section) : name
        }
    }

    // Nil where there is nothing to add, so the header collapses to one line.
    internal var subtitle: String? {
        switch self {
        case .empty:
            return nil
        case .tableRow(_, let position):
            guard let position else { return nil }
            return String(
                format: String(localized: "Row %@ of %@"),
                position.index.formatted(.number),
                position.total.formatted(.number)
            )
        case .multipleRows(_, let count):
            return String(format: String(localized: "%d rows selected"), count)
        case .definition(_, let section, let table):
            guard let table else { return Self.kindName(section) }
            return Self.kindName(section, of: table)
        case .tableOnly:
            return String(localized: "Table")
        }
    }

    private static func newDefinitionTitle(_ section: StructureSection) -> String {
        switch section {
        case .columns: String(localized: "New Column")
        case .indexes: String(localized: "New Index")
        case .foreignKeys: String(localized: "New Foreign Key")
        case .checkConstraints: String(localized: "New Check Constraint")
        }
    }

    private static func kindName(_ section: StructureSection) -> String {
        switch section {
        case .columns: String(localized: "Column")
        case .indexes: String(localized: "Index")
        case .foreignKeys: String(localized: "Foreign Key")
        case .checkConstraints: String(localized: "Check Constraint")
        }
    }

    private static func kindName(_ section: StructureSection, of table: String) -> String {
        switch section {
        case .columns: String(format: String(localized: "Column of %@"), table)
        case .indexes: String(format: String(localized: "Index of %@"), table)
        case .foreignKeys: String(format: String(localized: "Foreign Key of %@"), table)
        case .checkConstraints: String(format: String(localized: "Check Constraint of %@"), table)
        }
    }
}
