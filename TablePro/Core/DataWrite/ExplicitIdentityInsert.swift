//
//  ExplicitIdentityInsert.swift
//  TablePro
//

import Foundation

/// How an engine accepts an explicit value for a `GENERATED ALWAYS` or `IDENTITY` column, which a plain INSERT is
/// refused for. An engine not listed has no such form, and a write that needs one is refused instead.
enum ExplicitIdentityInsert: Equatable {
    /// PostgreSQL: `INSERT INTO t (...) OVERRIDING SYSTEM VALUE VALUES (...)`.
    case overridingSystemValue
    /// SQL Server: `SET IDENTITY_INSERT t ON` before the inserts and `OFF` after, on the same session. Only one table
    /// per session may hold it, and it needs ALTER permission on the table.
    case identityInsertSession

    static func style(for databaseType: DatabaseType) -> ExplicitIdentityInsert? {
        switch databaseType {
        case .postgresql, .pglite:
            return .overridingSystemValue
        case .mssql:
            return .identityInsertSession
        default:
            return nil
        }
    }

    static func sessionStatements(for qualifiedTable: String) -> (open: String, close: String) {
        ("SET IDENTITY_INSERT \(qualifiedTable) ON", "SET IDENTITY_INSERT \(qualifiedTable) OFF")
    }
}
