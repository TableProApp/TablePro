//
//  SQLiteRowidAlias.swift
//  TablePro
//

import Foundation

// SQLite's INTEGER PRIMARY KEY is the rowid: an INSERT that leaves it out takes the next one. A WITHOUT ROWID table has none.
enum SQLiteRowidAlias {
    static func isAlias(
        column: String,
        declaredType: String?,
        primaryKey: [String],
        family: SQLTypeFamily,
        hasRowID: Bool = true
    ) -> Bool {
        guard family == .sqlite, hasRowID, primaryKey == [column], let declaredType else { return false }
        return declaredType.trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER"
    }
}
