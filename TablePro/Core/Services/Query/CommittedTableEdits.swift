//
//  CommittedTableEdits.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// A table that a committed statement dropped or renamed, placed where it lived.
enum TableCatalogEdit: Equatable, Sendable {
    case dropped(TablePlacement, kind: TableInfo.TableType)
    case renamed(TablePlacement, to: String, kind: TableInfo.TableType)
}

/// What a connection's own SQL has done that can make a name resolve somewhere other than the
/// scope a tab records: a temporary table that shadows a real one, a schema moved by hand, or code
/// the server ran that the text does not show.
///
/// It only ever grows. Taking an entry back needs knowing that the temporary table is gone from
/// every session the connection runs SQL on, including one a rolled-back `DROP` left it in, and a
/// wrong entry only keeps a real table's settings where they are.
struct TableNameHazards: Sendable, Equatable {
    /// Lowercased, because SQLite, and MySQL on a case-insensitive file system, find a temporary
    /// `People` under `people`. Matching more loosely than an engine does only skips more.
    var temporaryNames: Set<String> = []
    var namesMayBeShadowed = false

    /// Records what a statement that ran, whether or not it succeeded, did to how names resolve. A
    /// failed procedure can have created a temporary table before it failed.
    mutating func record(_ statement: TableEditStatement, dialect: TableEditDialect) {
        switch statement {
        case .createsTemporaryTable(let name):
            guard dialect.temporaryTablesShadowRealOnes,
                  let table = name.parts.last.flatMap(dialect.folded) else { return }
            temporaryNames.insert(table.lowercased())
        case .losesSchemaContext, .runsUnseenCode:
            namesMayBeShadowed = true
        case .drop, .rename, .beginsTransaction, .commits, .rollsBack, .rollsBackToSavepoint,
             .losesTransactionTracking, .selectsDatabase, .other:
            break
        }
    }

    /// Whether `name`, placed as `table`, may be something other than the table the app keeps
    /// settings for.
    func mayShadow(_ name: SQLObjectName, placedAs table: TablePlacement, dialect: TableEditDialect) -> Bool {
        guard name.parts.count == 1 || dialect.temporaryTablesShadowQualifiedNames else { return false }
        return namesMayBeShadowed || temporaryNames.contains(table.name.lowercased())
    }
}

/// The drops and renames among statements that succeeded which are also committed, in the order
/// they ran.
///
/// Success is not enough on an engine whose DDL is transactional: `BEGIN; DROP TABLE people;
/// ROLLBACK` succeeds three times and leaves the table where it was. So the text's own `BEGIN`,
/// `COMMIT` and `ROLLBACK` are followed from a session known to hold no transaction, and an edit
/// still inside one when the statements end is dropped, because nothing here will see how it ends.
/// A run that began inside a transaction, or on a session that could not say, adopts nothing.
enum CommittedTableEdits {
    static func edits(
        in succeeded: SucceededStatements,
        grammar: SQLLexicalGrammar,
        hazards: inout TableNameHazards
    ) -> [TableCatalogEdit] {
        guard let dialect = TableEditDialect.of(succeeded.databaseType) else { return [] }
        var walk = TableEditWalk(dialect: dialect, scope: succeeded.scope, commit: succeeded.commit, hazards: hazards)
        for statement in succeeded.statements {
            walk.read(TableEditStatementParser.parse(statement, dialect: dialect, grammar: grammar))
        }
        walk.finish(succeeded.commit)
        hazards = walk.hazards
        return walk.committed
    }
}

private struct TableEditWalk {
    private let dialect: TableEditDialect
    private var context: TableNameContext
    /// Transaction nesting the text opened. A `COMMIT` commits only once it is back at zero, which
    /// is SQL Server's `@@TRANCOUNT`; on engines where one `COMMIT` ends everything this can only
    /// hold an edit back, never let one through early.
    private var depth = 0
    /// False when the session held a transaction the text cannot see the end of, in which case
    /// the walk only keeps the hazards current.
    private let adopts: Bool
    private var tracksTransactions = true
    private var pending: [TableCatalogEdit] = []
    private(set) var committed: [TableCatalogEdit] = []
    private(set) var hazards: TableNameHazards

    init(dialect: TableEditDialect, scope: DatabaseScope, commit: StatementCommitEvidence, hazards: TableNameHazards) {
        self.dialect = dialect
        context = TableNameContext(database: scope.database.nilIfEmpty, schema: scope.schema)
        adopts = Self.startsOutsideTransactions(commit, dialect: dialect)
        self.hazards = hazards
        if case .runStartedIn(_, .committed) = commit {
            depth = 1
        }
    }

    private static func startsOutsideTransactions(_ evidence: StatementCommitEvidence, dialect: TableEditDialect) -> Bool {
        guard !dialect.commitsDDLImplicitly else { return true }
        switch evidence {
        case .statementLeftSession(let state):
            return state.holdsNoTransaction
        case .runStartedIn(let state, let appTransaction):
            return state.holdsNoTransaction && appTransaction != .rolledBack
        }
    }

    /// The app's own `COMMIT`, which closes the transaction the walk opened for it, unless a
    /// `ROLLBACK` or `COMMIT` in the text already ended it.
    mutating func finish(_ evidence: StatementCommitEvidence) {
        guard case .runStartedIn(_, .committed) = evidence else { return }
        read(.commits)
    }

    mutating func read(_ statement: TableEditStatement) {
        hazards.record(statement, dialect: dialect)
        switch statement {
        case .drop(let names, let kind):
            for name in names {
                guard let table = place(name) else { continue }
                record(.dropped(table, kind: kind))
            }
        case .rename(let pairs, let kind):
            readRenames(pairs, kind: kind)
        case .beginsTransaction:
            depth += 1
        case .commits:
            guard depth > 0 else { return }
            depth -= 1
            guard depth == 0 else { return }
            committed += pending
            pending.removeAll()
        case .rollsBack:
            pending.removeAll()
            depth = 0
        case .rollsBackToSavepoint:
            pending.removeAll()
        case .losesTransactionTracking:
            pending.removeAll()
            tracksTransactions = false
        case .selectsDatabase(let name):
            context = dialect.context(afterUsing: name)
        case .losesSchemaContext:
            context.schema = nil
        case .createsTemporaryTable, .runsUnseenCode, .other:
            break
        }
    }

    private func place(_ name: SQLObjectName) -> TablePlacement? {
        guard let table = dialect.resolve(name, in: context),
              !hazards.mayShadow(name, placedAs: table, dialect: dialect) else { return nil }
        return table
    }

    /// Every pair or none: a chain such as `a TO tmp, b TO a, tmp TO b` applied in part would move
    /// one table's settings onto another. A rename that moves the table to another database or
    /// schema is left alone too, since the sidebar's own rename never does that.
    private mutating func readRenames(_ pairs: [SQLRenamePair], kind: TableInfo.TableType) {
        var edits: [TableCatalogEdit] = []
        for pair in pairs {
            guard let source = place(pair.from),
                  let target = renameTarget(pair.to, of: source),
                  target.container == source.container else { return }
            edits.append(.renamed(source, to: target.name, kind: kind))
        }
        for edit in edits {
            record(edit)
        }
    }

    private func renameTarget(_ target: SQLObjectName, of source: TablePlacement) -> TablePlacement? {
        guard dialect.renameKeepsContainer else { return dialect.resolve(target, in: context) }
        guard target.parts.count == 1, let name = dialect.folded(target.parts[0]) else { return nil }
        return TablePlacement(database: source.database, schema: source.schema, name: name)
    }

    private mutating func record(_ edit: TableCatalogEdit) {
        guard adopts else { return }
        if dialect.commitsDDLImplicitly {
            committed.append(edit)
            return
        }
        guard tracksTransactions else { return }
        if depth == 0 {
            committed.append(edit)
        } else {
            pending.append(edit)
        }
    }
}
