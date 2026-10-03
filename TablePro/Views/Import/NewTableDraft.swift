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
}

/// What the user set on one column, each setting nil until a write changes it. A read never touches
/// it, so a setting stays the user's even when a later read proposes the same value.
internal struct NewTableColumnEdits: Equatable {
    internal var include: Bool?
    internal var name: String?
    internal var type: String?
    internal var isPrimaryKey: Bool?
    internal var isNullable: Bool?
    internal var defaultValue: String?

    internal var isEmpty: Bool {
        self == NewTableColumnEdits()
    }

    internal func applied(to proposal: NewTableColumnSettings) -> NewTableColumnSettings {
        NewTableColumnSettings(
            include: include ?? proposal.include,
            name: name ?? proposal.name,
            type: type ?? proposal.type,
            isPrimaryKey: isPrimaryKey ?? proposal.isPrimaryKey,
            isNullable: isNullable ?? proposal.isNullable,
            defaultValue: defaultValue ?? proposal.defaultValue
        )
    }

    /// A type differing only in case is not a change: the type menu offers the dialect's own
    /// spelling of the type on show, and choosing it again writes that spelling back.
    internal func recording(
        _ settings: NewTableColumnSettings,
        over shown: NewTableColumnSettings
    ) -> NewTableColumnEdits {
        NewTableColumnEdits(
            include: settings.include == shown.include ? include : settings.include,
            name: settings.name == shown.name ? name : settings.name,
            type: settings.type.caseInsensitiveCompare(shown.type) == .orderedSame ? type : settings.type,
            isPrimaryKey: settings.isPrimaryKey == shown.isPrimaryKey ? isPrimaryKey : settings.isPrimaryKey,
            isNullable: settings.isNullable == shown.isNullable ? isNullable : settings.isNullable,
            defaultValue: settings.defaultValue == shown.defaultValue ? defaultValue : settings.defaultValue
        )
    }
}

/// One field of the file and the column the user is making of it.
internal struct NewTableColumn: Identifiable {
    internal let field: PluginImportField

    /// What the latest read proposes for this field.
    internal let proposal: NewTableColumnSettings
    internal private(set) var edits: NewTableColumnEdits

    internal init(
        field: PluginImportField,
        proposal: NewTableColumnSettings,
        edits: NewTableColumnEdits = NewTableColumnEdits()
    ) {
        self.field = field
        self.proposal = proposal
        self.edits = edits
    }

    internal var id: String { field.name }

    internal var settings: NewTableColumnSettings {
        get { edits.applied(to: proposal) }
        set { edits = edits.recording(newValue, over: settings) }
    }
}

internal enum NewTableColumnProblem: Equatable {
    case unnamedColumn
    case duplicateName
}

/// The table a row import creates: the fields of the file, what the sheet proposed for each, and
/// what the user changed.
///
/// Changing a parsing option reads the file again, and rebuilding the columns from that read threw
/// away every rename, type, key, nullability, default and exclusion the user had set. Each field
/// keeps the settings the user set, and each setting left alone follows the read, the way the
/// sheet's table name keeps what the user typed over its own suggestion.
internal struct NewTableDraft {
    internal var columns: [NewTableColumn] = []

    /// A wrong delimiter reads other fields for one read, and correcting it brings these back.
    private var setAsideEdits: [String: NewTableColumnEdits] = [:]

    internal mutating func load(
        fields: [PluginImportField],
        proposingType proposedType: (PluginImportFieldType) -> String
    ) {
        var edits = setAsideEdits
        for column in columns {
            edits[column.id] = column.edits
        }
        columns = fields.map { field in
            NewTableColumn(
                field: field,
                proposal: .proposed(name: field.name, type: proposedType(field.inferredType)),
                edits: edits.removeValue(forKey: field.name) ?? NewTableColumnEdits()
            )
        }
        setAsideEdits = edits.filter { !$0.value.isEmpty }
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
