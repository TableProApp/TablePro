//
//  DatabaseSearchOptions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DatabaseSearchMatchMode: String, CaseIterable, Identifiable, Sendable {
    case contains
    case exact
    case startsWith

    internal var id: String { rawValue }

    internal var displayName: String {
        switch self {
        case .contains: String(localized: "Contains")
        case .exact: String(localized: "Matches Exactly")
        case .startsWith: String(localized: "Starts With")
        }
    }

    internal var textOperator: FilterOperator {
        switch self {
        case .contains: .contains
        case .exact: .equal
        case .startsWith: .startsWith
        }
    }

    internal var usesPattern: Bool {
        self != .exact
    }
}

internal struct DatabaseSearchOptions: Equatable, Sendable {
    internal var term: String = ""
    internal var matchMode: DatabaseSearchMatchMode = .contains
    internal var isCaseSensitive = false
    internal var includesBinaryColumns = false

    internal var trimmedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

internal struct DatabaseSearchTarget: Hashable, Identifiable, Sendable {
    internal let name: String
    internal let schema: String?

    internal init(name: String, schema: String?) {
        self.name = name
        self.schema = schema?.isEmpty == true ? nil : schema
    }

    internal var id: String {
        IdentityPath.qualified(name: name, schema: schema)
    }

    internal var displayName: String {
        guard let schema else { return name }
        return "\(schema).\(name)"
    }
}

internal struct DatabaseSearchLaunchRequest: Hashable, Sendable {
    internal let database: String
    internal let schema: String?
}

internal enum DatabaseSearchEligibility {
    // PartiQL has no row limit to cap a table with, and CQL cannot match any one of several columns.
    internal static func supportsSearch(
        editorLanguage: EditorLanguage,
        dialect: SQLDialectDescriptor?,
        supportsMatchAnyFilters: Bool
    ) -> Bool {
        guard editorLanguage == .sql, let dialect, dialect.autoLimitStyle != .none else { return false }
        return supportsMatchAnyFilters
    }

    @MainActor
    internal static func supportsSearch(_ databaseType: DatabaseType) -> Bool {
        supportsSearch(
            editorLanguage: PluginManager.shared.editorLanguage(for: databaseType),
            dialect: try? resolveSQLDialect(for: databaseType),
            supportsMatchAnyFilters: PluginManager.shared.supportsMatchAnyFilters(for: databaseType)
        )
    }
}
