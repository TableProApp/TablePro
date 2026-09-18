//
//  SQLiteMaintenance.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

/// SQLite's maintenance operations and the statements they produce.
///
/// Pure, so the confirmation sheet's preview and the statement that runs are one function rather than
/// two implementations that drifted: the sheet printed `VACUUM orders` where `VACUUM` ran, and
/// `Integrity Check orders` where `PRAGMA integrity_check` ran.
///
/// Probed against SQLite 3.54.0. `VACUUM` and `PRAGMA integrity_check` act on the whole database and
/// name no object, which is why they are `.database`: the table the sheet printed beside them was
/// never in the statement. `ANALYZE` and `REINDEX` accept an object, and on a view both succeed and
/// do nothing, `ANALYZE "vw"` writing no `sqlite_stat1` row at all, so a view is not in their kind
/// sets. There is no kind error to go on here: a name SQLite does not recognise as a table is a
/// silent no-op reported as success.
nonisolated internal enum SQLiteMaintenance {
    internal static let vacuum = "VACUUM"
    internal static let analyze = "ANALYZE"
    internal static let reindex = "REINDEX"
    /// Not localized: it is the operation's identity, switched on here and sent to MCP clients as the
    /// name they pass back.
    internal static let integrityCheck = "Integrity Check"

    internal static let operations: [PluginMaintenanceOperation] = [
        PluginMaintenanceOperation(name: vacuum, appliesTo: [], scope: .database),
        PluginMaintenanceOperation(name: analyze, appliesTo: [.table], scope: .objectOrDatabase),
        PluginMaintenanceOperation(name: reindex, appliesTo: [.table], scope: .objectOrDatabase),
        PluginMaintenanceOperation(name: integrityCheck, appliesTo: [], scope: .database)
    ]

    internal static func statements(operation: String, table: String?) -> [String]? {
        switch operation {
        case vacuum:
            return [vacuum]
        case analyze:
            return [table.map { "ANALYZE \(sqliteQuoteIdentifier($0))" } ?? "ANALYZE"]
        case reindex:
            return [table.map { "REINDEX \(sqliteQuoteIdentifier($0))" } ?? "REINDEX"]
        case integrityCheck:
            return ["PRAGMA integrity_check"]
        default:
            return nil
        }
    }
}
