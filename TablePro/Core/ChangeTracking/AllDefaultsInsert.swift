//
//  AllDefaultsInsert.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The INSERT for a row whose every column the server fills in. It names no value, which is legal SQL with its own
/// spelling per engine. Returning nothing instead dropped the row from a save while the rest committed and reported
/// success, so a new row in a table of nothing but an identity column and defaults vanished without a word.
enum AllDefaultsInsert {
    /// Nil where the engine has no such spelling, or where it needs a column to name and the table has none left.
    static func sql(into qualifiedTable: String, databaseType: DatabaseType, firstWritableColumn: String?) -> String? {
        switch SqlDialect.from(databaseTypeId: databaseType.rawValue) {
        case .postgres, .sqlite:
            return "INSERT INTO \(qualifiedTable) DEFAULT VALUES"
        case .mysql:
            return "INSERT INTO \(qualifiedTable) () VALUES ()"
        default:
            break
        }
        switch databaseType {
        case .mssql:
            return "INSERT INTO \(qualifiedTable) DEFAULT VALUES"
        case .databend, .oracle:
            guard let firstWritableColumn else { return nil }
            return "INSERT INTO \(qualifiedTable) (\(firstWritableColumn)) VALUES (DEFAULT)"
        default:
            return nil
        }
    }
}
