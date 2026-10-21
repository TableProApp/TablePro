//
//  RowImportTarget.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowImportDestination: Hashable {
    case existingTable
    case newTable
}

/// Where one file's rows go and how its fields reach the columns, as a run of several files holds it for each file
/// and as `RowImportSheet` edits it for one of them.
internal struct RowImportTarget {
    /// The fields of the file against the columns of an existing table, as one read found them.
    internal struct Mapping {
        internal let table: String
        internal let fields: [PluginImportField]
        internal let columns: [String]
        internal var choices: [ImportFieldChoice]

        internal var fieldNames: [String] {
            fields.map(\.name)
        }

        internal var columnMapping: [String: String] {
            var mapping: [String: String] = [:]
            for (field, choice) in zip(fields, choices) {
                guard let column = choice.mappedColumn else { continue }
                mapping[field.name] = column
            }
            return mapping
        }

        internal var mappedFieldCount: Int {
            choices.filter { $0.mappedColumn != nil }.count
        }

        internal var mapsOneColumnTwice: Bool {
            let targets = choices.compactMap { $0.mappedColumn?.lowercased() }
            return Set(targets).count != targets.count
        }

        internal var choicesByField: [String: ImportFieldChoice] {
            Dictionary(zip(fieldNames, choices), uniquingKeysWith: { first, _ in first })
        }
    }

    internal var destination: RowImportDestination
    internal var existingTable: String?
    internal var newTableName: String

    /// The last name proposed for the new table, so a later proposal can tell its own guess from a typed name.
    internal var proposedTableName: String
    internal var mapping: Mapping?
    internal var newTable: NewTableDraft

    internal static func newTable(named name: String) -> RowImportTarget {
        RowImportTarget(
            destination: .newTable,
            existingTable: nil,
            newTableName: name,
            proposedTableName: name,
            mapping: nil,
            newTable: NewTableDraft()
        )
    }

    internal static func existingTable(_ table: String, proposingNewTable name: String) -> RowImportTarget {
        RowImportTarget(
            destination: .existingTable,
            existingTable: table,
            newTableName: name,
            proposedTableName: name,
            mapping: nil,
            newTable: NewTableDraft()
        )
    }

    /// The table the rows go to, trimmed the way the import names it.
    internal var tableName: String? {
        switch destination {
        case .existingTable:
            return existingTable
        case .newTable:
            let trimmed = newTableName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// What `RowImportSheet` needs to edit one file of several instead of importing it.
internal struct RowImportSheetEdit {
    internal let scope: DatabaseScope
    internal let target: RowImportTarget
    internal let planner: NewTableImportPlanner

    /// Folded names the other files of the run create, which this file's new table must not take.
    internal let takenTableNames: Set<String>
    internal let onDone: @MainActor (RowImportTarget) -> Void
}

internal extension NewTableNameProblem {
    func message(for name: String) -> String {
        switch self {
        case .blank:
            return String(localized: "Enter a name for the new table.")
        case .nameTaken:
            return String(
                format: String(localized: "A table named %@ already exists."),
                name.trimmingCharacters(in: .whitespaces)
            )
        case .reservedPrefix(let prefix):
            return String(
                format: String(localized: "This database keeps names beginning with %@ for itself."),
                prefix
            )
        case .tooLong(let maximumBytes):
            return String(
                format: String(localized: "This database allows at most %lld bytes in a table name."),
                Int64(maximumBytes)
            )
        }
    }
}

internal extension NewTableColumnProblem {
    var message: String {
        switch self {
        case .unnamedColumn:
            return String(localized: "Every included column needs a name.")
        case .duplicateName:
            return String(localized: "Column names must be unique.")
        }
    }
}
