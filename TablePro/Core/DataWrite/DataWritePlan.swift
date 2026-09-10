//
//  DataWritePlan.swift
//  TablePro
//
//  What one press of Save is about to do, as an object.
//
//  The save path used to hand the executor a flat array of statements with the foreign-key
//  toggles, the row edits and the TRUNCATEs all mixed together and nothing saying which was
//  which. That array could not answer the three questions the app needs: how many rows should
//  this touch, which part of it can be undone afterwards, and what would a person read if we
//  showed it to them. A plan answers all three because it keeps the row that produced each
//  statement attached to it.
//

import Foundation
import TableProPluginKit

enum RowWriteKind: String, Codable, Sendable, Equatable {
    case insert
    case update
    case delete

    /// What taking this write back is: an insert becomes a delete, a delete becomes an insert, and
    /// an update stays an update with its two images the other way round.
    var inverted: RowWriteKind {
        switch self {
        case .insert: return .delete
        case .delete: return .insert
        case .update: return .update
        }
    }
}

/// Where a row lives, independently of the tab that was showing it.
struct DataWriteTarget: Codable, Sendable, Hashable {
    let database: String
    let schema: String?
    let table: String

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }
}

/// One row the save is about to write, with everything a later rewind would need.
struct RowWriteOperation: Codable, Sendable, Equatable {
    let kind: RowWriteKind
    let target: DataWriteTarget
    let columns: [String]
    let primaryKeyColumns: [String]
    /// The row as it stood before the write. Absent for an insert, which had no before.
    let preImage: [PluginCellValue]?
    /// The row as it should stand after the write. Absent for a delete, which has no after.
    let postImage: [PluginCellValue]?
    /// The columns this write actually set. A rewind compares only these, so a trigger touching
    /// some other column does not read as a conflict.
    let writtenColumns: [String]
    /// Why this row cannot be rewound, or nil when it can.
    let refusal: RewindRefusal?

    var isReversible: Bool { refusal == nil }
}

/// One statement, and how many rows it is allowed to touch.
struct DataWriteStep: Sendable {
    enum Kind: Sendable, Equatable {
        case rowWrite
        case tableOperation
        case foreignKeyToggle
    }

    let kind: Kind
    let statement: ParameterizedStatement
    /// The most rows this statement may legitimately touch, or nil when the engine's count for it
    /// carries no meaning: DDL, a session setting, or a statement a plugin wrote itself, where
    /// nothing tells the host which rows went into it.
    let expectedRowCount: Int?
    let tableName: String?

    init(
        kind: Kind,
        statement: ParameterizedStatement,
        expectedRowCount: Int? = nil,
        tableName: String? = nil
    ) {
        self.kind = kind
        self.statement = statement
        self.expectedRowCount = expectedRowCount
        self.tableName = tableName
    }
}

/// The statements a change set produces, beside the record of the rows behind them.
struct RowWriteBuild: Sendable {
    let steps: [DataWriteStep]
    let operations: [RowWriteOperation]
}

struct DataWritePlan: Sendable {
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let steps: [DataWriteStep]
    /// The rows this plan writes, in the order the user changed them. Built from the change set
    /// rather than from the statements, so it is complete even for a driver that writes its own.
    let rowOperations: [RowWriteOperation]
    /// Statements that must run before the transaction opens, never inside it.
    ///
    /// SQLite, libSQL and Cloudflare D1 disable foreign keys with `PRAGMA foreign_keys = OFF`,
    /// which SQLite documents as a no-op inside a transaction. Run there, "Ignore foreign key
    /// checks" silently does nothing. MySQL's session variable would work either side, so outside
    /// is the placement that is correct for every engine rather than most of them.
    let prologue: [String]

    /// Statements that must run after the transaction, never inside it. They run on the way out of
    /// both a commit and a rollback, because leaving foreign keys disabled is worse than the
    /// failure that got there.
    let epilogue: [String]

    init(
        scope: DatabaseScope,
        databaseType: DatabaseType,
        steps: [DataWriteStep],
        rowOperations: [RowWriteOperation] = [],
        prologue: [String] = [],
        epilogue: [String] = []
    ) {
        self.scope = scope
        self.databaseType = databaseType
        self.steps = steps
        self.rowOperations = rowOperations
        self.prologue = prologue
        self.epilogue = epilogue
    }

    var statements: [ParameterizedStatement] {
        (prologue + epilogue).isEmpty
            ? steps.map(\.statement)
            : prologue.map { ParameterizedStatement(sql: $0, parameters: []) }
                + steps.map(\.statement)
                + epilogue.map { ParameterizedStatement(sql: $0, parameters: []) }
    }

    var containsTableOperation: Bool {
        steps.contains { $0.kind == .tableOperation }
    }

    var isEmpty: Bool {
        steps.allSatisfy { $0.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && prologue.isEmpty
    }

    /// The plan as a person would read it, with the bound values written in.
    ///
    /// Everything that asks a human to approve a write reads this: the Preview SQL sheet, the
    /// Safe Mode confirmation and the authorization gate. Showing them the parameterized form
    /// asks someone to approve `WHERE "id" = ?`, which names no row at all.
    var displayStatements: [String] {
        prologue
            + steps.map { SQLParameterInliner.inline($0.statement, databaseType: databaseType) }
            + epilogue
    }

    var displaySQL: String {
        displayStatements.joined(separator: "\n")
    }
}
