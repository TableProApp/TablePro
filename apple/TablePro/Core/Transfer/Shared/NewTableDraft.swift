import Foundation
import TableProPluginKit

// What a row import makes of one field of the file in the table it creates.
nonisolated struct NewTableColumnSettings: Equatable {
    var include: Bool
    var name: String
    var type: String
    var isPrimaryKey: Bool
    var isNullable: Bool
    var defaultValue: String

    static func proposed(name: String, type: String) -> NewTableColumnSettings {
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

// What the user set on one column, each setting nil until a write changes it. A read never touches it, so a setting
// stays the user's even when a later read proposes the same value.
nonisolated struct NewTableColumnEdits: Equatable {
    var include: Bool?
    var name: String?
    var type: String?
    var isPrimaryKey: Bool?
    var isNullable: Bool?
    var defaultValue: String?

    var isEmpty: Bool {
        self == NewTableColumnEdits()
    }

    func applied(to proposal: NewTableColumnSettings) -> NewTableColumnSettings {
        NewTableColumnSettings(
            include: include ?? proposal.include,
            name: name ?? proposal.name,
            type: type ?? proposal.type,
            isPrimaryKey: isPrimaryKey ?? proposal.isPrimaryKey,
            isNullable: isNullable ?? proposal.isNullable,
            defaultValue: defaultValue ?? proposal.defaultValue
        )
    }

    // A type differing only in case is not a change: the type menu offers the dialect's own spelling of the type on
    // show, and choosing it again writes that spelling back.
    func recording(
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

nonisolated struct NewTableColumn: Identifiable {
    let field: PluginImportField
    // What the latest read proposes for this field.
    let proposal: NewTableColumnSettings
    private(set) var edits: NewTableColumnEdits

    init(
        field: PluginImportField,
        proposal: NewTableColumnSettings,
        edits: NewTableColumnEdits = NewTableColumnEdits()
    ) {
        self.field = field
        self.proposal = proposal
        self.edits = edits
    }

    var id: String { field.name }

    var settings: NewTableColumnSettings {
        get { edits.applied(to: proposal) }
        set { edits = edits.recording(newValue, over: settings) }
    }
}

nonisolated enum NewTableColumnProblem: Equatable {
    case unnamedColumn
    case duplicateName

    var message: String {
        switch self {
        case .unnamedColumn:
            return String(localized: "Every included column needs a name.")
        case .duplicateName:
            return String(localized: "Column names must be unique.")
        }
    }
}

// Changing a parsing option reads the file again, and rebuilding the columns from that read threw away every rename,
// type, key, nullability, default and exclusion the user had set. Each field keeps the settings the user set, and each
// setting left alone follows the read, the way the sheet's table name keeps what the user typed over its suggestion.
nonisolated struct NewTableDraft {
    var columns: [NewTableColumn] = []

    // A wrong delimiter reads other fields for one read, and correcting it brings these back.
    private var setAsideEdits: [String: NewTableColumnEdits] = [:]

    mutating func load(
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

    var includesEveryColumn: Bool {
        !columns.isEmpty && columns.allSatisfy(\.settings.include)
    }

    mutating func setAllIncluded(_ include: Bool) {
        for index in columns.indices {
            columns[index].settings.include = include
        }
    }

    // Every field of the file in file order, the ones left out of the table included.
    var fields: [String] {
        columns.map(\.field.name)
    }

    // The column each field is written to, for every included field whose column has a name.
    var columnMapping: [String: String] {
        var mapping: [String: String] = [:]
        for column in namedColumns {
            mapping[column.field.name] = column.settings.name
        }
        return mapping
    }

    var hasNamedColumn: Bool {
        !namedColumns.isEmpty
    }

    var problem: NewTableColumnProblem? {
        let names = columns
            .filter(\.settings.include)
            .map { $0.settings.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains(where: \.isEmpty) {
            return .unnamedColumn
        }
        return Set(names).count == names.count ? nil : .duplicateName
    }

    // Nil when no included column has both a name and a type, which leaves nothing to create.
    func definition(tableName: String) -> PluginCreateTableDefinition? {
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
