//
//  PluginSessionTransactionState+Execution.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension DatabaseDriver {
    /// What the session is holding, asked only of an engine that has transactions at all: one
    /// without them has nothing to report, and nothing the app owns opens a transaction on it.
    func heldSessionTransactionState() async -> PluginSessionTransactionState {
        guard supportsTransactions else { return .unknown }
        return await sessionTransactionState()
    }
}

/// The one reading of a session's state that every app-owned writer on the session route shares.
///
/// A multi-statement run, a grid Save and a grid Discard all send their own `BEGIN`, `COMMIT` and
/// `ROLLBACK` down the connection's shared session. They must agree about when that is allowed, or
/// the editor joins the user's transaction while a cell edit still commits it.
internal extension PluginSessionTransactionState {
    /// Whether the app may open a transaction of its own on this session, and therefore commit and
    /// roll it back.
    ///
    /// `.unknown` answers true, which is what the app did before it could ask: every batch's
    /// atomicity outweighs a transaction that may not be there on an engine that cannot say.
    var permitsAppTransaction: Bool {
        switch self {
        case .idle, .unknown:
            return true
        case .inTransaction, .abortedTransaction, .holdsSessionLocks:
            return false
        @unknown default:
            return true
        }
    }

    /// What the user has to be told about the transaction this session is holding, or nil when it
    /// is holding none.
    ///
    /// The aborted case says nothing about committing on purpose. Measured on PostgreSQL 17.11, a
    /// `COMMIT` in an aborted block answers with the command tag `ROLLBACK` and no error at all, so
    /// "commit or roll it back" is advice that silently discards the work it was meant to keep.
    var openTransactionNotice: String? {
        switch self {
        case .inTransaction:
            return String(localized: "The transaction on this connection is still open. Commit or roll it back.")
        case .abortedTransaction:
            return String(localized: "The transaction on this connection can no longer be committed. Roll it back.")
        case .idle, .holdsSessionLocks, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }
}
