//
//  CompareObjectKind.swift
//  TablePro
//
//  What a compared object is. `fetchTables` reports views alongside tables, and
//  nothing filtered on the kind, so a view reached the table paths and produced
//  CREATE TABLE for a view or INSERT against one.
//
//  The rule is subtractive rather than an allow-list: PostgreSQL reports
//  PARTITIONED TABLE for an ordinary, directly queryable table, so matching the
//  literal string TABLE would silently drop it from every comparison.
//

import Foundation
import TableProPluginKit

internal enum CompareObjectKind: String, Codable, Hashable, Sendable, CaseIterable {
    case table
    case view
    case materializedView
    case procedure
    case function
    case trigger
    case sequence

    internal var displayName: String {
        switch self {
        case .table: return String(localized: "Table")
        case .view: return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .procedure: return String(localized: "Procedure")
        case .function: return String(localized: "Function")
        case .trigger: return String(localized: "Trigger")
        case .sequence: return String(localized: "Sequence")
        }
    }

    /// Only a table holds rows a data comparison can walk.
    internal var carriesRows: Bool {
        self == .table
    }

    /// Objects whose definition is a body of SQL text rather than a set of columns.
    internal var isSourceDefined: Bool {
        switch self {
        case .procedure, .function, .trigger, .view, .materializedView: return true
        case .table, .sequence: return false
        }
    }
}

internal enum CompareTableKindClassifier {
    /// `fetchTables` mixes tables and views, and each driver spells the kind its own way.
    /// Anything not recognised as a view is treated as a table, because a driver that reports
    /// an unfamiliar table-like kind should still be compared rather than silently dropped.
    internal static func kind(of table: PluginTableInfo) -> CompareObjectKind {
        let normalized = table.type
            .uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if normalized.contains("MATERIALIZED") { return .materializedView }
        if normalized.contains("VIEW") { return .view }
        return .table
    }

    /// A foreign table is a proxy for data on another server. Comparing its structure is
    /// meaningful; writing rows through it is not, so it is excluded from data compare.
    internal static func isForeign(_ table: PluginTableInfo) -> Bool {
        table.type.uppercased().contains("FOREIGN")
    }
}
