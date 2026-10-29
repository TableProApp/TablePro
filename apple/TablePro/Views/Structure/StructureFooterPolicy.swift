//
//  StructureFooterPolicy.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The add and remove pair beneath each section's table: what it is called and which edit it stages.
enum StructureFooterPolicy {
    static func operation(forAdding section: StructureSection) -> StructureEditOperation {
        switch section {
        case .columns: .addColumn
        case .indexes: .addIndex
        case .foreignKeys: .addForeignKey
        case .checkConstraints: .addCheckConstraint
        }
    }

    static func operation(forRemoving section: StructureSection) -> StructureEditOperation {
        switch section {
        case .columns: .dropColumn
        case .indexes: .dropIndex
        case .foreignKeys: .dropForeignKey
        case .checkConstraints: .dropCheckConstraint
        }
    }

    // Why the tables and the pairs under them take no edits while a save runs.
    static var savingReason: String {
        String(localized: "The staged changes are being saved.")
    }

    static func labels(for section: StructureSection) -> (add: String, remove: String) {
        switch section {
        case .columns:
            (String(localized: "Add Column"), String(localized: "Remove Column"))
        case .indexes:
            (String(localized: "Add Index"), String(localized: "Remove Index"))
        case .foreignKeys:
            (String(localized: "Add Foreign Key"), String(localized: "Remove Foreign Key"))
        case .checkConstraints:
            (String(localized: "Add Check Constraint"), String(localized: "Remove Check Constraint"))
        }
    }
}
