import Foundation

public enum PluginViewRowEditing: Sendable, Equatable {
    case editable(PluginViewWriteTarget)
    case readOnly(PluginViewReadOnlyReason)

    public var writeTarget: PluginViewWriteTarget? {
        if case .editable(let target) = self { return target }
        return nil
    }

    // Engines return early for what only they can see; the rest of the answer is the same everywhere.
    public static func resolve(
        operations: PluginViewWriteOperations,
        baseTable: PluginViewBaseTable,
        columns: [PluginViewColumn],
        baseKeyColumns: [String]?,
        baseColumns: [PluginViewBaseColumn]?
    ) -> PluginViewRowEditing {
        guard operations.contains(.update) else { return .readOnly(.notUpdatable) }
        guard let baseKeyColumns else { return .readOnly(.baseTableHidden) }
        guard !baseKeyColumns.isEmpty else { return .readOnly(.baseTableHasNoKey) }

        var keyColumns: [String] = []
        for baseKey in baseKeyColumns {
            guard let shown = columns.first(where: { $0.baseColumn == baseKey }) else {
                return .readOnly(.keyNotExposed)
            }
            keyColumns.append(shown.name)
        }

        var baseByName: [String: PluginViewBaseColumn] = [:]
        for column in baseColumns ?? [] where baseByName[column.name] == nil {
            baseByName[column.name] = column
        }

        var readOnlyColumns: Set<String> = []
        var baseColumnNames: [String: String] = [:]
        var shownBaseColumns: [String: PluginViewBaseColumn] = [:]
        var assignedBaseColumns: Set<String> = []
        for column in columns {
            guard let baseName = column.baseColumn else {
                readOnlyColumns.insert(column.name)
                continue
            }
            baseColumnNames[column.name] = baseName
            let base = baseByName[baseName]
            shownBaseColumns[column.name] = base
            // A second view column over one base column would assign it twice in one statement.
            let isFirstShowing = assignedBaseColumns.insert(baseName).inserted
            if !column.acceptsWrites || base?.acceptsWrites == false || !isFirstShowing {
                readOnlyColumns.insert(column.name)
            }
        }

        var allowed = operations
        if let baseColumns {
            let filled = Set(columns.filter { !readOnlyColumns.contains($0.name) }.compactMap(\.baseColumn))
            if baseColumns.contains(where: { $0.isRequiredOnInsert && !filled.contains($0.name) }) {
                allowed.remove(.insert)
            }
        } else {
            allowed.remove(.insert)
        }

        return .editable(PluginViewWriteTarget(
            baseTable: baseTable,
            keyColumns: keyColumns,
            readOnlyColumns: readOnlyColumns,
            operations: allowed,
            baseColumnNames: baseColumnNames,
            baseColumns: shownBaseColumns
        ))
    }
}

public enum PluginViewReadOnlyReason: String, Sendable, Equatable {
    case notUpdatable
    case writesRunTriggers
    case readsSeveralTables
    case baseTableHidden
    case baseTableHasNoKey
    case keyNotExposed
    // A read failed after the relation proved to be a view.
    case couldNotCheck
}

public struct PluginViewWriteOperations: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let update = PluginViewWriteOperations(rawValue: 1 << 0)
    public static let insert = PluginViewWriteOperations(rawValue: 1 << 1)
    public static let delete = PluginViewWriteOperations(rawValue: 1 << 2)
    public static let all: PluginViewWriteOperations = [.update, .insert, .delete]
}

public struct PluginViewWriteTarget: Sendable, Equatable {
    public let baseTable: PluginViewBaseTable
    public let keyColumns: [String]
    public let readOnlyColumns: Set<String>
    public let operations: PluginViewWriteOperations
    public let baseColumnNames: [String: String]
    // Only for base columns the user may read; empty when the server hides them.
    public let baseColumns: [String: PluginViewBaseColumn]

    public init(
        baseTable: PluginViewBaseTable,
        keyColumns: [String],
        readOnlyColumns: Set<String>,
        operations: PluginViewWriteOperations,
        baseColumnNames: [String: String],
        baseColumns: [String: PluginViewBaseColumn]
    ) {
        self.baseTable = baseTable
        self.keyColumns = keyColumns
        self.readOnlyColumns = readOnlyColumns
        self.operations = operations
        self.baseColumnNames = baseColumnNames
        self.baseColumns = baseColumns
    }

    public var baseKeyColumns: [String] {
        keyColumns.map { baseColumnNames[$0] ?? $0 }
    }
}

public struct PluginViewBaseTable: Sendable, Hashable {
    // Nil means the view's own database or schema.
    public let database: String?
    public let schema: String?
    public let name: String

    public init(database: String? = nil, schema: String? = nil, name: String) {
        self.database = database
        self.schema = schema
        self.name = name
    }
}

public struct PluginViewColumn: Sendable, Equatable {
    public let name: String
    // Nil for a computed column.
    public let baseColumn: String?
    public let acceptsWrites: Bool

    public init(name: String, baseColumn: String?, acceptsWrites: Bool) {
        self.name = name
        self.baseColumn = baseColumn
        self.acceptsWrites = acceptsWrites
    }
}

public struct PluginViewBaseColumn: Sendable, Equatable {
    public let name: String
    public let isNullable: Bool
    public let defaultValue: String?
    // An identity, auto increment or rowversion column: the server fills it when an INSERT leaves it out.
    public let assignsValue: Bool
    // False for a generated column and for an identity the server refuses an explicit value for.
    public let acceptsWrites: Bool

    public init(name: String, isNullable: Bool, defaultValue: String?, assignsValue: Bool, acceptsWrites: Bool) {
        self.name = name
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.assignsValue = assignsValue
        self.acceptsWrites = acceptsWrites
    }

    public var isRequiredOnInsert: Bool {
        acceptsWrites && !isNullable && defaultValue == nil && !assignsValue
    }
}
