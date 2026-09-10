//
//  PluginExportObjectKind.swift
//  TableProPluginKit
//

import Foundation

/// What a selected export item is. The vocabulary grows as engines gain object types, so this is
/// deliberately not `@frozen` and every switch over it needs a `default:`.
public enum PluginExportObjectKind: String, Codable, Sendable, CaseIterable {
    case table
    case view
    case materializedView
    case foreignTable
    case sequence
    case userType
    case routine
    case trigger
    case event
    case grant

    /// Where this kind belongs in a dump, so a restore replays it after everything it depends on.
    /// Types and sequences precede the tables that reference them, views and routines follow the
    /// tables they read, triggers follow the routines they may call, and grants come last because
    /// they name objects that must already exist.
    public var dumpOrder: Int {
        switch self {
        case .userType: return 0
        case .sequence: return 1
        case .table: return 2
        case .foreignTable: return 3
        case .view: return 4
        case .materializedView: return 5
        case .routine: return 6
        case .trigger: return 7
        case .event: return 8
        case .grant: return 9
        }
    }

    /// Whether the object holds rows an export can stream. Everything else is definition only.
    public var carriesRows: Bool {
        switch self {
        case .table, .foreignTable: return true
        default: return false
        }
    }

    /// The keyword a `DROP` for this kind uses, without the object name.
    public var dropKeyword: String {
        switch self {
        case .table: return "DROP TABLE"
        case .view: return "DROP VIEW"
        case .materializedView: return "DROP MATERIALIZED VIEW"
        case .foreignTable: return "DROP FOREIGN TABLE"
        case .sequence: return "DROP SEQUENCE"
        case .userType: return "DROP TYPE"
        case .routine: return "DROP ROUTINE"
        case .trigger: return "DROP TRIGGER"
        case .event: return "DROP EVENT"
        case .grant: return ""
        }
    }

    /// The kinds an export format receives when it does not declare its own set. A format written
    /// before object scope existed only ever saw tables and views, so that is what it keeps
    /// receiving: handing it a routine would run its table code path over a definition.
    public static var legacyDefault: [PluginExportObjectKind] { [.table, .view] }

    /// Maps the `tableType` string an export item carries. The spelling comes from engine metadata,
    /// so it is matched loosely rather than by equality.
    public static func from(tableType: String) -> PluginExportObjectKind {
        let normalized = tableType.lowercased()
        if normalized.contains("materialized") { return .materializedView }
        if normalized.contains("foreign") { return .foreignTable }
        if normalized.contains("view") { return .view }
        return .table
    }
}
