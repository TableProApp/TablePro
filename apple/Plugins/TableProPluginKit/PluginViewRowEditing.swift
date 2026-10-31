//
//  PluginViewRowEditing.swift
//  TableProPluginKit
//

import Foundation

/// Whether the data grid may write rows through one view, and which view columns identify a row.
///
/// An edit through a view is keyed on its base table's primary key: without every key column in
/// the view, an `UPDATE` or `DELETE` could match more rows than the one the user changed.
public enum PluginViewRowEditing: Sendable, Equatable {
    case editable(keyColumns: [String])
    case readOnly(PluginViewReadOnlyReason)

    public var keyColumns: [String]? {
        if case .editable(let keyColumns) = self { return keyColumns }
        return nil
    }

    /// The rule every engine shares once it knows the server's verdict, how many tables the view
    /// reads, its base table's key, and which base column each view column shows.
    public static func resolve(
        isUpdatable: Bool,
        baseTableCount: Int,
        baseKeyColumns: [String],
        origins: [PluginViewColumnOrigin]
    ) -> PluginViewRowEditing {
        guard isUpdatable, baseTableCount > 0 else { return .readOnly(.notUpdatable) }
        guard baseTableCount == 1 else { return .readOnly(.readsSeveralTables) }
        guard !baseKeyColumns.isEmpty else { return .readOnly(.baseTableHasNoKey) }

        var keyColumns: [String] = []
        for baseColumn in baseKeyColumns {
            guard let origin = origins.first(where: { $0.baseColumn == baseColumn }) else {
                return .readOnly(.keyNotExposed)
            }
            keyColumns.append(origin.viewColumn)
        }
        return .editable(keyColumns: keyColumns)
    }
}

public enum PluginViewReadOnlyReason: String, Sendable, Equatable {
    case notUpdatable
    case readsSeveralTables
    case baseTableHasNoKey
    case keyNotExposed
}

/// One view column that shows a base table column unchanged. A computed column has no origin.
public struct PluginViewColumnOrigin: Sendable, Equatable {
    public let viewColumn: String
    public let baseColumn: String

    public init(viewColumn: String, baseColumn: String) {
        self.viewColumn = viewColumn
        self.baseColumn = baseColumn
    }
}

public extension PluginDatabaseDriver {
    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? { nil }
}
