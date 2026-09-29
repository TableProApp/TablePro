//
//  SucceededStatements.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// What became of a transaction the app opened around a run.
enum AppTransactionOutcome: Sendable, Equatable {
    /// The app opened none.
    case none
    /// The app opened one and its `COMMIT` answered. A `ROLLBACK` in the script's own text can
    /// still have ended it earlier, which is why the edits inside it wait for that `COMMIT`.
    case committed
    case rolledBack
}

/// What the session said about committing statements that ran without an error.
enum StatementCommitEvidence: Sendable, Equatable {
    /// One statement, and what the session held once it had run.
    case statementLeftSession(PluginSessionTransactionState)
    /// Several statements, what the session held before the first of them, and what became of a
    /// transaction the app opened around them.
    case runStartedIn(PluginSessionTransactionState, appTransaction: AppTransactionOutcome)

    static func run(
        startedIn state: PluginSessionTransactionState,
        plan: BatchTransactionPlan,
        completed: Bool
    ) -> StatementCommitEvidence {
        guard plan.opensTransaction else { return .runStartedIn(state, appTransaction: .none) }
        return .runStartedIn(state, appTransaction: completed ? .committed : .rolledBack)
    }
}

/// SQL a user or an MCP client ran, the statements of it that succeeded, in order, and the scope
/// they started in.
///
/// Kept apart from `CatalogEvent.statementsRan`, which reports a failed statement as well because
/// a refresh errs toward running. What this one carries is acted on as a drop or a rename, so it
/// holds only what the server accepted.
struct SucceededStatements: Sendable, Equatable {
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let statements: [String]
    let commit: StatementCommitEvidence

    /// A statement that ran alone, when it drops or renames a table, or changes how a name
    /// resolves. The session is asked what it holds only where the answer decides anything, which
    /// an engine that commits DDL as it runs never needs.
    static func single(
        _ sql: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar,
        ranOn driver: DatabaseDriver
    ) async -> SucceededStatements? {
        guard let dialect = TableEditDialect.of(databaseType) else { return nil }
        let statement = TableEditStatementParser.parse(sql, dialect: dialect, grammar: grammar)
        guard statement.editsTable || statement.changesNameHazards else { return nil }
        let asksSession = statement.editsTable && !dialect.commitsDDLImplicitly
        let state: PluginSessionTransactionState = asksSession ? await driver.heldSessionTransactionState() : .unknown
        return SucceededStatements(
            scope: scope, databaseType: databaseType, statements: [sql], commit: .statementLeftSession(state)
        )
    }
}

extension PluginSessionTransactionState {
    /// Whether whatever ran before this answer has been committed.
    var holdsNoTransaction: Bool {
        switch self {
        case .idle, .holdsSessionLocks:
            return true
        case .inTransaction, .abortedTransaction, .unknown:
            return false
        @unknown default:
            return false
        }
    }
}
