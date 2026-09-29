//
//  NewTableDraft.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What a row import makes of one field of the file in the table it creates.
internal struct NewTableColumnSettings: Equatable {
    internal var include: Bool
    internal var name: String
    internal var type: String
    internal var isPrimaryKey: Bool
    internal var isNullable: Bool
    internal var defaultValue: String

    /// Every field, under its own name and with the type its values suggest, nullable, with no key
    /// and no default.
    internal static func proposed(name: String, type: String) -> NewTableColumnSettings {
        NewTableColumnSettings(
            include: true,
            name: name,
            type: type,
            isPrimaryKey: false,
            isNullable: true,
            defaultValue: ""
        )
    }

    /// A setting still equal to what the sheet proposed was never changed, so it takes the new
    /// proposal. One the user moved away from the proposal is theirs and stays. A type that differs
    /// from the proposal only in case is the proposal, because the type menu offers the dialect's
    /// own spelling of it.
    internal func keepingEdits(
        madeTo earlier: NewTableColumnSettings,
        over proposal: NewTableColumnSettings
    ) -> NewTableColumnSettings {
        NewTableColumnSettings(
            include: include == earlier.include ? proposal.include : include,
            name: name == earlier.name ? proposal.name : name,
            type: type.caseInsensitiveCompare(earlier.type) == .orderedSame ? proposal.type : type,
            isPrimaryKey: isPrimaryKey == earlier.isPrimaryKey ? proposal.isPrimaryKey : isPrimaryKey,
            isNullable: isNullable == earlier.isNullable ? proposal.isNullable : isNullable,
            defaultValue: defaultValue == earlier.defaultValue ? proposal.defaultValue : defaultValue
        )
    }
}

/// One field of the file and the column the user is making of it.
internal struct NewTableColumn: Identifiable {
    internal let field: PluginImportField

    /// What the sheet offered for this field on the read that produced it, so the next read can tell
    /// the user's changes from the sheet's own guesses.
    internal let proposal: NewTableColumnSettings
    internal var settings: NewTableColumnSettings

    internal var id: String { field.name }
}

internal enum NewTableColumnProblem: Equatable {
    case unnamedColumn
    case duplicateName
}

/// The table a row import creates: the fields of the file, what the sheet proposed for each, and
/// what the user changed.
///
/// Changing a parsing option reads the file again, and rebuilding the columns from that read threw
/// away every rename, type, key, nullability, default and exclusion the user had set. A field that
/// survives the read keeps each setting the user changed, and each setting left as proposed follows
/// the read, the way the sheet's table name keeps what the user typed over its own suggestion.
internal struct NewTableDraft {
    internal var columns: [NewTableColumn] = []

    internal mutating func load(
        fields: [PluginImportField],
        proposingType proposedType: (PluginImportFieldType) -> String
    ) {
        let earlier = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        columns = fields.map { field in
            let proposal = NewTableColumnSettings.proposed(name: field.name, type: proposedType(field.inferredType))
            let settings = earlier[field.name].map { $0.settings.keepingEdits(madeTo: $0.proposal, over: proposal) }
            return NewTableColumn(field: field, proposal: proposal, settings: settings ?? proposal)
        }
    }

    internal var includesEveryColumn: Bool {
        !columns.isEmpty && columns.allSatisfy(\.settings.include)
    }

    internal mutating func setAllIncluded(_ include: Bool) {
        for index in columns.indices {
            columns[index].settings.include = include
        }
    }

    /// Every field of the file in file order, the ones left out of the table included.
    internal var fields: [String] {
        columns.map(\.field.name)
    }

    /// The column each field is written to, for every included field whose column has a name.
    internal var columnMapping: [String: String] {
        var mapping: [String: String] = [:]
        for column in namedColumns {
            mapping[column.field.name] = column.settings.name
        }
        return mapping
    }

    internal var hasNamedColumn: Bool {
        !namedColumns.isEmpty
    }

    internal var problem: NewTableColumnProblem? {
        let names = columns
            .filter(\.settings.include)
            .map { $0.settings.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains(where: \.isEmpty) {
            return .unnamedColumn
        }
        return Set(names).count == names.count ? nil : .duplicateName
    }

    /// Nil when no included column has both a name and a type, which leaves nothing to create.
    internal func definition(tableName: String) -> PluginCreateTableDefinition? {
        let included = namedColumns
            .map(\.settings)
            .filter { !$0.type.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !included.isEmpty else { return nil }
        return PluginCreateTableDefinition(
            tableName: tableName,
            columns: included.map { column in
                PluginColumnDefinition(
                    name: column.name,
                    dataType: column.type,
                    isNullable: column.isNullable,
                    defaultValue: column.defaultValue.isEmpty ? nil : column.defaultValue,
                    isPrimaryKey: column.isPrimaryKey,
                    autoIncrement: false,
                    comment: nil,
                    unsigned: false,
                    onUpdate: nil,
                    charset: nil,
                    collation: nil
                )
            },
            primaryKeyColumns: included.filter(\.isPrimaryKey).map(\.name)
        )
    }

    private var namedColumns: [NewTableColumn] {
        columns.filter {
            $0.settings.include && !$0.settings.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
