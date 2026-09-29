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
        case .rename(let pairs, _):
            guard dialect.temporaryTablesShadowRealOnes else { return }
            for pair in pairs where isTemporary(pair.from, dialect: dialect) {
                guard let target = pair.to.parts.last.flatMap(dialect.folded) else { continue }
                temporaryNames.insert(target.lowercased())
            }
        case .losesSchemaContext, .runsUnseenCode:
            namesMayBeShadowed = true
        case .drop, .beginsTransaction, .commits, .rollsBack, .rollsBackToSavepoint,
             .losesTransactionTracking, .selectsDatabase, .controlsFlow, .other:
            break
        }
    }

    /// A temporary table keeps shadowing under the name it is renamed to, as SQLite's
    /// `ALTER TABLE scratch RENAME TO people` does.
    private func isTemporary(_ name: SQLObjectName, dialect: TableEditDialect) -> Bool {
        if name.parts.dropLast().contains(where: { dialect.namesTemporaryContainer($0.text) }) { return true }
        guard let table = name.parts.last.flatMap(dialect.folded) else { return false }
        return temporaryNames.contains(table.lowercased())
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
/// `COMMIT` and `ROLLBACK` are followed, and only between two answers from the session that it
/// held no transaction, one before the first statement and one after the last. The text alone
/// cannot be trusted even then: under SQL Server's `IMPLICIT_TRANSACTIONS`, set by an earlier run
/// or by the server's defaults, a `DROP` opens a transaction no statement shows. A run that ends
/// inside a transaction, closes one it never opened, or leaves one open that the session says is
/// closed has met such a transaction, and adopts nothing.
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
    /// False when the session held a transaction at either end, or the text and the session
    /// disagreed about one, in which case the walk only keeps the hazards current.
    private var adopts: Bool
    private var tracksTransactions = true
    private var pending: [TableCatalogEdit] = []
    private(set) var committed: [TableCatalogEdit] = []
    private(set) var hazards: TableNameHazards

    init(dialect: TableEditDialect, scope: DatabaseScope, commit: StatementCommitEvidence, hazards: TableNameHazards) {
        self.dialect = dialect
        context = TableNameContext(database: scope.database.nilIfEmpty, schema: scope.schema)
        adopts = Self.runsOutsideTransactions(commit, dialect: dialect)
        self.hazards = hazards
        if case .runStartedIn(_, _, .committed) = commit {
            depth = 1
        }
    }

    private static func runsOutsideTransactions(_ evidence: StatementCommitEvidence, dialect: TableEditDialect) -> Bool {
        guard !dialect.commitsDDLImplicitly else { return true }
        switch evidence {
        case .statementLeftSession(let state):
            return state.holdsNoTransaction
        case .runStartedIn(let start, let end, let appTransaction):
            return start.holdsNoTransaction && end.holdsNoTransaction && appTransaction != .rolledBack
        }
    }

    /// The app's own `COMMIT`, which closes the transaction the walk opened for it, unless a
    /// `ROLLBACK` or `COMMIT` in the text already ended it. A transaction the text still holds
    /// after that was closed by something it does not show, since the session says none is open.
    mutating func finish(_ evidence: StatementCommitEvidence) {
        if case .runStartedIn(_, _, .committed) = evidence, depth > 0 {
            endTransaction()
        }
        if depth > 0 {
            disown()
        }
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
            guard depth > 0 else {
                disown()
                return
            }
            endTransaction()
        case .rollsBack:
            guard depth > 0 else {
                disown()
                return
            }
            pending.removeAll()
            depth = 0
        case .rollsBackToSavepoint:
            guard depth > 0 else {
                disown()
                return
            }
            pending.removeAll()
        case .losesTransactionTracking:
            pending.removeAll()
            tracksTransactions = false
        case .selectsDatabase(let name):
            context = dialect.context(afterUsing: name)
        case .losesSchemaContext:
            context.schema = nil
        case .controlsFlow:
            stopAdopting()
        case .createsTemporaryTable, .runsUnseenCode, .other:
            break
        }
    }

    private mutating func endTransaction() {
        depth -= 1
        guard depth == 0 else { return }
        committed += pending
        pending.removeAll()
    }

    /// The text and the session disagree about the transaction, so what the text says was
    /// committed is not known to be. On PostgreSQL a stray `COMMIT` or `ROLLBACK` is only a
    /// warning, and this holds back a drop that did commit, which keeps its settings in place.
    private mutating func disown() {
        guard !dialect.commitsDDLImplicitly else { return }
        stopAdopting()
    }

    /// Nothing the run did is known to have happened, the edits before this point included.
    private mutating func stopAdopting() {
        adopts = false
        committed.removeAll()
        pending.removeAll()
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
