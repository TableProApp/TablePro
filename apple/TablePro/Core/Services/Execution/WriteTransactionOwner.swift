//
//  WriteTransactionOwner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Who owns the transaction an app-owned write runs inside, and therefore who may commit it.
///
/// A grid Save, Discard or Rewind, a structure rebuild and a batch from the editor all run on the
/// connection's shared session, so a `BEGIN` the user typed into the editor, a `SET autocommit = 0`,
/// a `LOCK TABLES` or an MCP client's `begin` is still in force when the write arrives. Opening a
/// transaction of its own then commits their pending work on PostgreSQL, implicitly commits it on
/// MySQL and aborts it on DuckDB, with nothing raised and the write reporting success.
///
/// This is the one place that decision is made. ``BatchTransactionPlan/joining(_:commitMode:)`` is
/// the same decision for a multi-statement run, where the statement text has a say as well.
internal enum WriteTransactionOwner: Equatable {
    /// The app opens the transaction, verifies inside it, and commits or rolls it back.
    case app
    // Manual Commit: the app opens the transaction and leaves it open for the user to commit, rolling back only a failure.
    case held
    /// The session already holds one. The write joins it and sends no `BEGIN`, `COMMIT` or
    /// `ROLLBACK`: ending it belongs to whoever opened it.
    case session
    /// The engine has no transactions, so every statement is on the server as it runs.
    case none

    // No default for the mode: a writer off the session's turn must say `.automatic`, or its hold is never seen.
    internal static func resolve(
        supportsTransactions: Bool,
        sessionState: PluginSessionTransactionState,
        commitMode: ConnectionCommitMode
    ) -> WriteTransactionOwner {
        guard supportsTransactions else { return .none }
        if commitMode == .manual, sessionState == .idle { return .held }
        return sessionState.permitsAppTransaction ? .app : .session
    }

    internal var sendsBegin: Bool {
        switch self {
        case .app, .held:
            return true
        case .session, .none:
            return false
        }
    }

    internal var commitsAtEnd: Bool {
        switch self {
        case .app:
            return true
        case .held, .session, .none:
            return false
        }
    }

    /// Whether the statements that already ran can still be taken back by the app.
    internal var canRollBack: Bool {
        switch self {
        case .app, .held:
            return true
        case .session, .none:
            return false
        }
    }
}
