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
    struct Action {
        /// What the confirming button says, which is the only thing that differs between a reorder
        /// and a constraint change: both recreate the table, and the user is reading the same script.
        let title: String
        /// The operation the gate is told it is authorizing, which the sheet is titled with.
        let operationDescription: String
        let perform: () async -> Void
    }

    let id = UUID()
    let tableName: String

    /// The database and schema the plan was built against, carried so the script opens where it
    /// belongs. The connection's browse database can be somewhere else by the time the sheet is
    /// answered, and PostgreSQL cannot qualify a table with a database, so an unqualified script
    /// opened on the wrong one would rebuild a same-named table there.
    let scope: DatabaseScope

    let plan: PluginColumnReorderPlan

    let action: Action?

    /// A rebuild drops the table it copied, so a sheet that can run it warns the way the gate's own
    /// sheet does for a destructive statement, ahead of what the rebuild cannot carry over.
    var warning: String? {
        let dataWarning = runnableAction.map { _ in OperationConfirmationPrompt.destructiveDataWarning }
        let lines = [dataWarning].compactMap { $0 } + plan.caveats
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    var isRunnable: Bool { plan.isRunnable }

    var runnableAction: Action? {
        isRunnable ? action : nil
    }

    var scriptStatements: [String] { plan.scriptStatements }

    /// A sheet that can run the script is that script's only confirmation: the run it starts tells
    /// the gate so. It therefore reads as the gate's own sheet does, titled with the operation,
    /// naming the connection, and showing the script uncut. A preview keeps the preview heading.
    var confirmationTitle: String? { runnableAction?.operationDescription }

    var showsStatementsVerbatim: Bool { runnableAction != nil }

    func confirmationSubtitle(connectionName: String?) -> String? {
        guard runnableAction != nil else { return nil }
        return OperationConfirmationPrompt.subtitle(connectionName: connectionName, caller: .userInterface)
    }
}
