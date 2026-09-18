//
//  TableRebuildReviewRequest.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A structure change whose plan recreates the table, held while the user reads it.
///
/// A positional `ALTER` runs on the drop the way any other direct manipulation does. A rebuild
/// copies every row into a new table and drops the original, so it is shown in full and confirmed
/// first, and what the rebuild cannot carry over is named beside it.
@MainActor
struct TableRebuildReviewRequest: Identifiable {
    let id = UUID()
    let tableName: String

    /// The database and schema the plan was built against, carried so the script opens where it
    /// belongs. The connection's browse database can be somewhere else by the time the sheet is
    /// answered, and PostgreSQL cannot qualify a table with a database, so an unqualified script
    /// opened on the wrong one would rebuild a same-named table there.
    let scope: DatabaseScope

    let plan: PluginColumnReorderPlan

    /// What the confirming button says, which is the only thing that differs between a reorder and
    /// a constraint change: both recreate the table, and the user is reading the same script.
    let actionTitle: String

    let perform: () async -> Void

    var warning: String? {
        plan.caveats.isEmpty ? nil : plan.caveats.joined(separator: " ")
    }

    var isRunnable: Bool { plan.isRunnable }

    var scriptStatements: [String] { plan.scriptStatements }
}
