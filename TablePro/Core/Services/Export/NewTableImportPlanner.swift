//
//  NewTableImportPlanner.swift
//  TablePro
//

import Foundation

enum NewTableImportPlan: Equatable {
    case create
    case reuseAfterClearing
    case nameTakenWithDifferentColumns
}

/// What a row import into a new table should do about the table itself.
///
/// A failed import leaves the table it created behind, so the next attempt finds the name taken. It
/// cannot simply create again, and it cannot simply carry on either: Stop and Commit keeps the batch
/// it managed to write, and so does any run with transaction wrapping turned off, so importing into
/// the table as it stands would write those rows a second time. The table is only ever reused when
/// this sheet created it in this session with exactly the columns being asked for now, which is the
/// one case where clearing it can lose nothing but the sheet's own failed attempt.
///
/// A table is known by its database and schema as well as its name. Keyed by name alone, a table the
/// sheet made in one database vouched for a same-named table in another, and the retry cleared that
/// one with `DELETE FROM`.
struct NewTableImportPlanner {
    private var createStatements: [TableScope: String] = [:]

    func plan(forTable table: TableScope, createTableSQL: String) -> NewTableImportPlan {
        guard let previousSQL = createStatements[table] else {
            return .create
        }
        return previousSQL == createTableSQL ? .reuseAfterClearing : .nameTakenWithDifferentColumns
    }

    func created(_ table: TableScope) -> Bool {
        createStatements[table] != nil
    }

    func createdTableNames(in scope: DatabaseScope) -> [String] {
        createStatements.keys
            .filter { $0 == TableScope(table: $0.table, in: scope) }
            .map(\.table)
    }

    mutating func recordCreated(_ table: TableScope, createTableSQL: String) {
        createStatements[table] = createTableSQL
    }
}
