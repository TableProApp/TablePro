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
import TableProPluginKit

/// One table's work: its DDL, and the read and write it will stream between.
internal struct ObjectCopyTableStep: Identifiable, Sendable {
    internal let selection: ObjectCopySelection
    /// Runs first, and only when the user chose to replace a table the target already has.
    internal let dropStatements: [SyncStatement]
    /// The sequences this table's own defaults name, created before it.
    ///
    /// A PostgreSQL `SERIAL` column's default is `nextval('seq'::regclass)`. Copied without its
    /// sequence, the table either refuses to be created or arrives with a default pointing at
    /// nothing, and the first insert fails.
    internal let sequenceStatements: [SyncStatement]
    internal let createStatements: [SyncStatement]
    /// Empties a table the copy is about to append to, for a data-only replace where there is no
    /// DROP and CREATE to clear it.
    ///
    /// Not part of the DDL phase. Every clear runs before any table is filled, because clearing
    /// each table immediately before its own rows let the first parent DELETE meet child rows that
    /// were still there and a cascading key took rows out of tables the user never selected. But
    /// the clears belong inside the data phase's own transaction, not in a phase of their own:
    /// run ahead of it they deleted the target's rows for good while a later failure rolled only
    /// the new rows back. `ObjectCopyPlan.clearsInsideDataTransaction` is where those two meet.
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
    /// What the crossing changed about this table's structure, listed before anything runs. Empty
    /// within one type family, and empty for a step that writes no structure.
    internal let conversionNotes: [CrossEngineConversionNote]
    /// Reshapes the values whose spelling the two engines disagree about. Nil where they agree.
    internal let coercer: CrossEngineValueCoercer?
    /// The one statement that copies this table's rows without them leaving the server. Set only
    /// when both sides are the same connection; nil means the rows are streamed through the app.
    internal let serverSideInsert: SyncStatement?
    /// Set when this table is in the plan but part of it cannot run, so the sheet can say why
    /// before the user presses Copy.
    internal let note: String?

    /// Spelled out rather than left to the memberwise init so the three fields a same-engine copy
    /// never sets can default. Every one of them describes something only a crossing or a
    /// same-connection copy produces, and a caller that has neither should not have to say so.
    internal init(
        selection: ObjectCopySelection,
        dropStatements: [SyncStatement],
        sequenceStatements: [SyncStatement],
        createStatements: [SyncStatement],
        truncateStatements: [SyncStatement],
        columns: [String],
        primaryKeyColumns: [String],
        sourceQuery: String,
        targetTable: String,
        targetSchema: String?,
        estimatedRows: Int?,
        copiesData: Bool,
        copiesIdentityColumn: Bool,
        conversionNotes: [CrossEngineConversionNote] = [],
        coercer: CrossEngineValueCoercer? = nil,
        serverSideInsert: SyncStatement? = nil,
        note: String?
    ) {
        self.selection = selection
        self.dropStatements = dropStatements
        self.sequenceStatements = sequenceStatements
        self.createStatements = createStatements
        self.truncateStatements = truncateStatements
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.sourceQuery = sourceQuery
        self.targetTable = targetTable
        self.targetSchema = targetSchema
        self.estimatedRows = estimatedRows
        self.copiesData = copiesData
        self.copiesIdentityColumn = copiesIdentityColumn
        self.conversionNotes = conversionNotes
        self.coercer = coercer
        self.serverSideInsert = serverSideInsert
        self.note = note
    }

    internal var id: String { selection.id }

    /// What the DDL phase runs for this table. The truncate is deliberately absent: it belongs to
    /// the data phase's transaction.
    internal var ddl: [SyncStatement] { dropStatements + sequenceStatements + createStatements }

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
    /// The schemas a duplicated database needs before its first table, one statement each.
    ///
    /// A new database arrives with whatever schema its engine gives it and nothing else, so
    /// `CREATE TABLE "sales"."invoices"` names a schema that is not there. These run ahead of every
    /// other statement in the structure phase and belong to no selection: nothing can be created if
    /// the schema it goes in could not be.
    internal let schemaStatements: [SyncStatement]
    internal let skipped: [ObjectCopySkip]

    internal init(
        request: ObjectCopyRequest,
        createsDatabase: Bool,
        tableSteps: [ObjectCopyTableStep],
        definitionSteps: [ObjectCopyDefinitionStep],
        schemaStatements: [SyncStatement] = [],
        skipped: [ObjectCopySkip] = []
    ) {
        self.request = request
        self.createsDatabase = createsDatabase
        self.tableSteps = tableSteps
        self.definitionSteps = definitionSteps
        self.schemaStatements = schemaStatements
        self.skipped = skipped
    }

    /// Shown above the script, for the caveats the copy cannot do anything about: a key column the
    /// server insists on generating refuses the value the source holds, and the table's own error
    /// is the first the user sees.
    ///
    /// A crossing between engines is named here as well as itemised below, because the itemised
    /// list is per column and the fact that the types were rewritten at all is per copy.
    internal var warnings: [String] {
        var warnings: [String] = []
        /// Asked of the steps rather than of `conversionNotes`, which flattens and sorts every
        /// note in the plan. This is read from a view body on every redraw, and a copy of a
        /// hundred tables has thousands of them.
        if tableSteps.contains(where: { !$0.conversionNotes.isEmpty }) {
            warnings.append(String(
                format: String(
                    localized: "%1$@ and %2$@ do not share a type system, so the structure below was rewritten. Check it before copying."
                ),
                request.source.databaseType.rawValue, request.target.databaseType.rawValue
            ))
        }
        if dataSteps.contains(where: { $0.serverSideInsert != nil }) {
            warnings.append(String(
                localized: "Both sides are one connection, so the server copies the rows itself. There is no row-by-row progress, and Stop cannot interrupt it."
            ))
        }
        guard dataSteps.contains(where: \.copiesIdentityColumn) else { return warnings }
        warnings.append(String(
            localized: "Identity and auto-increment values are written as they are. A column the server generates always may refuse them."
        ))
        return warnings
    }

    /// Every type, default and index the crossing changed, worst first.
    internal var conversionNotes: [CrossEngineConversionNote] {
        tableSteps.flatMap(\.conversionNotes).orderedForReview
    }

    /// What the review step lists, and how many it could not.
    ///
    /// A whole-database crossing produces a note per converted column, which on a hundred tables is
    /// thousands of them. The list is inside a `ScrollView` rather than a `List`, so SwiftUI builds
    /// every row it is given whether or not any of them is on screen. The worst are first, so a cap
    /// keeps exactly the ones worth reading.
    internal func reviewedConversionNotes(
        limit: Int = 200
    ) -> (shown: [CrossEngineConversionNote], hidden: Int) {
        let ordered = conversionNotes
        guard ordered.count > limit else { return (ordered, 0) }
        return (Array(ordered.prefix(limit)), ordered.count - limit)
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
        schemaStatements + cleanupStatements + creationStatements + afterDataStatements
    }

    /// Cleanup runs children first, so a foreign key is gone before the table it points at, and a
    /// trigger before the table that owns it. Creation then runs parents first. Doing both in one
    /// parent-first pass had every DROP rejected by the constraint below it.
    internal var cleanupGroups: [ObjectCopyStatementGroup] {
        definitionSteps.reversed().map { ObjectCopyStatementGroup($0.selection, $0.dropStatements) }
            + tableSteps.reversed().map { ObjectCopyStatementGroup($0.selection, $0.dropStatements) }
    }

    internal var creationGroups: [ObjectCopyStatementGroup] {
        tableSteps.map { ObjectCopyStatementGroup($0.selection, $0.sequenceStatements + $0.createStatements) }
            + definitionSteps.filter { !$0.runsAfterData }
                .map { ObjectCopyStatementGroup($0.selection, $0.createStatements) }
    }

    /// Emptying the tables a data-only replace appends to, children first so a foreign key holds.
    ///
    /// Only a table whose rows are going back in. A step that copies no data is not in `dataSteps`,
    /// so clearing it deletes every row the target had and writes nothing in their place: the
    /// review said only that the two sides shared no writable column, and the run reported success.
    internal var clearGroups: [ObjectCopyStatementGroup] {
        tableSteps.reversed()
            .filter { $0.copiesData && !$0.truncateStatements.isEmpty }
            .map { ObjectCopyStatementGroup($0.selection, $0.truncateStatements) }
    }

    /// Whether the clears run inside the data phase's transaction rather than ahead of it.
    ///
    /// Emptying a table is reversible only while the transaction that emptied it is still open, so
    /// a run that promises a rollback cannot put its DELETEs in a phase of their own: the first
    /// failure afterwards leaves the target's own rows gone with nothing written in their place.
    /// A run that promises nothing keeps them in a phase of their own, where one table's failure
    /// does not reach the tables already copied.
    internal var clearsInsideDataTransaction: Bool {
        !clearGroups.isEmpty
            && request.wrapEachTableInTransaction
            && request.errorHandling != .skipAndContinue
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
    ///
    /// The clears are one block ahead of every data step, which is the order the runner uses. Shown
    /// against each table instead, the script said the parent was emptied after the child had been
    /// filled, and a user reasoning about a cascade from what they were asked to approve reached
    /// the opposite conclusion from what the run would do.
    internal var scriptText: String {
        var lines: [String] = []
        if case .newDatabase(_, let name, _) = request.destination {
            lines.append(String(format: String(localized: "-- Create database %@"), name))
        }
        lines += schemaStatements.map(\.sql)
        lines += cleanupStatements.map(\.sql)
        lines += creationStatements.map(\.sql)
        let clears = clearGroups.flatMap(\.statements)
        if !clears.isEmpty {
            lines.append("")
            lines.append(String(localized: "-- Empty the tables the rows go into"))
            lines += clears.map(\.sql)
        }
        for step in dataSteps {
            lines.append("")
            lines.append(String(format: String(localized: "-- Copy rows into %@"), step.qualifiedTargetName))
            /// The statement itself where the server runs it, because that one is real SQL the
            /// user is about to approve. The streamed path has no statement to show: its INSERTs
            /// do not exist yet and never all exist at once, so the query it walks stands in.
            lines.append(step.serverSideInsert?.sql ?? step.sourceQuery + ";")
        }
        guard !afterDataStatements.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append(String(localized: "-- Once the rows are in"))
        lines += afterDataStatements.map(\.sql)
        return lines.joined(separator: "\n")
    }
}
