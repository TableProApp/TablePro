//
//  ObjectCopyPlan.swift
//  TablePro
//
//  What the run will do, resolved against both sides before anything is written.
//
//  The DDL is spelled out because a user can read it and refuse. The rows are
//  not: one INSERT per row is the cost this feature exists to avoid holding, so
//  a table's data step carries the query it will walk and the columns it will
//  write, and the rows arrive one batch at a time while the run is going.
//

import Foundation

/// One table's work: its DDL, and the read and write it will stream between.
internal struct ObjectCopyTableStep: Identifiable, Sendable {
    internal let selection: ObjectCopySelection
    /// Runs first, and only when the user chose to replace a table the target already has.
    internal let dropStatements: [SyncStatement]
    internal let createStatements: [SyncStatement]
    /// Empties a table the copy is about to append to, for a data-only replace where there is no
    /// DROP and CREATE to clear it.
    ///
    /// Not part of the DDL phase: it runs inside the same transaction as this table's rows, so a
    /// copy that fails or is stopped puts the target's own rows back. Run ahead of the transaction
    /// it deleted them for good while rolling only the new rows back.
    internal let truncateStatements: [SyncStatement]
    /// The columns written, source order, with generated columns already removed. Empty when this
    /// step copies structure only.
    internal let columns: [String]
    internal let primaryKeyColumns: [String]
    internal let sourceQuery: String
    internal let targetTable: String
    internal let targetSchema: String?
    /// The driver's own estimate, for the progress bar. Nil where the driver has none.
    internal let estimatedRows: Int?
    internal let copiesData: Bool
    /// True when a column this step writes is one the server may insist on generating itself.
    internal let copiesIdentityColumn: Bool
    /// Set when this table is in the plan but part of it cannot run, so the sheet can say why
    /// before the user presses Copy.
    internal let note: String?

    internal var id: String { selection.id }

    /// What the DDL phase runs for this table. The truncate is deliberately absent: it belongs to
    /// the data phase's transaction.
    internal var ddl: [SyncStatement] { dropStatements + createStatements }

    internal var qualifiedTargetName: String {
        guard let targetSchema, !targetSchema.isEmpty else { return targetTable }
        return "\(targetSchema).\(targetTable)"
    }
}

/// One view, routine or trigger: its definition is SQL text, so there is nothing to stream.
///
/// The drop and the create are kept apart because they run in different phases and in opposite
/// orders: everything is torn down children first, then built parents first.
internal struct ObjectCopyDefinitionStep: Identifiable, Sendable {
    internal let selection: ObjectCopySelection
    internal let dropStatements: [SyncStatement]
    internal let createStatements: [SyncStatement]

    internal var id: String { selection.id }

    internal var statements: [SyncStatement] { dropStatements + createStatements }

    /// A trigger fires on the rows the copy is about to write, so installing one before the data
    /// phase makes the copy trip it: an audit trigger writes a second row for every row copied,
    /// and a validating one rejects rows the source already holds.
    internal var runsAfterData: Bool {
        selection.kind == .trigger || selection.kind == .materializedView
    }
}

/// One object's statements for one phase, so a failure is attributed to the object that caused it.
internal struct ObjectCopyStatementGroup: Sendable {
    internal let selection: ObjectCopySelection
    internal let statements: [SyncStatement]

    internal init(_ selection: ObjectCopySelection, _ statements: [SyncStatement]) {
        self.selection = selection
        self.statements = statements
    }
}

/// An object left out, with the reason, so nothing disappears without saying so.
internal struct ObjectCopySkip: Identifiable, Sendable {
    internal let selection: ObjectCopySelection
    internal let reason: String

    internal var id: String { selection.id }
}

internal struct ObjectCopyPlan: Sendable {
    internal let request: ObjectCopyRequest
    internal let createsDatabase: Bool
    internal let tableSteps: [ObjectCopyTableStep]
    internal let definitionSteps: [ObjectCopyDefinitionStep]
    internal let skipped: [ObjectCopySkip]

    internal init(
        request: ObjectCopyRequest,
        createsDatabase: Bool,
        tableSteps: [ObjectCopyTableStep],
        definitionSteps: [ObjectCopyDefinitionStep],
        skipped: [ObjectCopySkip] = []
    ) {
        self.request = request
        self.createsDatabase = createsDatabase
        self.tableSteps = tableSteps
        self.definitionSteps = definitionSteps
        self.skipped = skipped
    }

    /// Shown above the script. The engine cannot differ any more, so the one caveat left is the
    /// one the copy cannot do anything about: a key column the server insists on generating
    /// refuses the value the source holds, and the table's own error is the first the user sees.
    internal var warnings: [String] {
        guard dataSteps.contains(where: \.copiesIdentityColumn) else { return [] }
        return [String(
            localized: "Identity and auto-increment values are written as they are. A column the server generates always may refuse them."
        )]
    }

    /// Emptiness is about work, not about steps. A data-only copy into a table the target does not
    /// have, and a structure-only copy set to add rows to a table it already has, both keep a step
    /// that runs nothing: the review then showed an empty script and Copy reported success over
    /// zero objects.
    internal var isEmpty: Bool {
        !createsDatabase && ddlStatements.isEmpty && dataSteps.isEmpty
    }

    /// Everything the run writes that is not a row, in the order it writes it.
    internal var ddlStatements: [SyncStatement] {
        cleanupStatements + creationStatements + afterDataStatements
    }

    /// Cleanup runs children first, so a foreign key is gone before the table it points at, and a
    /// trigger before the table that owns it. Creation then runs parents first. Doing both in one
    /// parent-first pass had every DROP rejected by the constraint below it.
    internal var cleanupGroups: [ObjectCopyStatementGroup] {
        definitionSteps.reversed().map { ObjectCopyStatementGroup($0.selection, $0.dropStatements) }
            + tableSteps.reversed().map { ObjectCopyStatementGroup($0.selection, $0.dropStatements) }
    }

    internal var creationGroups: [ObjectCopyStatementGroup] {
        tableSteps.map { ObjectCopyStatementGroup($0.selection, $0.createStatements) }
            + definitionSteps.filter { !$0.runsAfterData }
                .map { ObjectCopyStatementGroup($0.selection, $0.createStatements) }
    }

    /// Emptying the tables a data-only replace appends to, children first so a foreign key holds.
    internal var clearGroups: [ObjectCopyStatementGroup] {
        tableSteps.reversed()
            .filter { !$0.truncateStatements.isEmpty }
            .map { ObjectCopyStatementGroup($0.selection, $0.truncateStatements) }
    }

    /// The definitions held back until the rows are in: a trigger fires on the copy itself, and a
    /// materialized view is filled at the moment it is created, so one built over an empty table
    /// stays empty.
    internal var afterDataGroups: [ObjectCopyStatementGroup] {
        definitionSteps.filter(\.runsAfterData)
            .map { ObjectCopyStatementGroup($0.selection, $0.createStatements) }
    }

    internal var cleanupStatements: [SyncStatement] { cleanupGroups.flatMap(\.statements) }
    internal var creationStatements: [SyncStatement] { creationGroups.flatMap(\.statements) }
    internal var afterDataStatements: [SyncStatement] { afterDataGroups.flatMap(\.statements) }

    internal var dataSteps: [ObjectCopyTableStep] {
        tableSteps.filter(\.copiesData)
    }

    /// The sum the progress bar counts against, in rows. A table the driver has no estimate for
    /// contributes nothing, so the bar can only run ahead of itself, never behind.
    internal var estimatedRowTotal: Int {
        dataSteps.reduce(0) { $0 + ($1.estimatedRows ?? 0) }
    }

    /// What the user reads before pressing Copy. The DDL verbatim, then one line per table naming
    /// what its data step will walk, because the INSERTs themselves do not exist yet.
    internal var scriptText: String {
        var lines: [String] = []
        if case .newDatabase(_, let name, _) = request.destination {
            lines.append(String(format: String(localized: "-- Create database %@"), name))
        }
        lines += cleanupStatements.map(\.sql)
        lines += creationStatements.map(\.sql)
        for step in dataSteps {
            lines.append("")
            lines.append(String(format: String(localized: "-- Copy rows into %@"), step.qualifiedTargetName))
            lines += step.truncateStatements.map(\.sql)
            lines.append(step.sourceQuery + ";")
        }
        guard !afterDataStatements.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append(String(localized: "-- Once the rows are in"))
        lines += afterDataStatements.map(\.sql)
        return lines.joined(separator: "\n")
    }
}
