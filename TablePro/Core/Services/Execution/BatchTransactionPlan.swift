//
//  BatchTransactionPlan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How a multi-statement run treats the transaction around it.
///
/// `.autocommit` is the answer for a batch holding a statement the engine refuses, or silently
/// ignores, inside a transaction block: `VACUUM`, `CREATE INDEX CONCURRENTLY`, `SET sql_log_bin`,
/// `PRAGMA foreign_keys`. Such a batch opens nothing, commits nothing, and rolls nothing back,
/// because there is no transaction of its own to roll back to.
///
/// `.sessionTransaction` is the answer the text cannot reach: it comes from the driver, once the
/// lease is held, through ``joining(_:)``.
///
/// The switches over this are exhaustive on purpose. No case may inherit `.appTransaction`'s begin
/// or `.scriptTransaction`'s rollback by falling into a `default:` arm.
internal enum BatchTransactionPlan: Equatable, Sendable {
    /// The app opens the transaction, commits it, and rolls it back on a failure or a Stop.
    case appTransaction
    /// The script opens its own transaction. The app opens none and still rolls back what a failed
    /// script left open.
    case scriptTransaction
    /// Every statement commits as it runs.
    case autocommit
    /// The transaction, or the table lock, is the session's own, so the run touches neither: no
    /// `BEGIN`, no `COMMIT`, no `ROLLBACK`. The user's text decides instead, and a joined script
    /// ending in `COMMIT` commits.
    case sessionTransaction

    internal var opensTransaction: Bool {
        switch self {
        case .appTransaction:
            return true
        case .scriptTransaction, .autocommit, .sessionTransaction:
            return false
        }
    }

    internal var rollsBackAfterStop: Bool {
        switch self {
        case .appTransaction, .scriptTransaction:
            return true
        case .autocommit, .sessionTransaction:
            return false
        }
    }

    /// Whether the statements that ran before a failure or a Stop stay in place. The failure banner
    /// says so, and a stopped run keeps their results and their history rather than dropping them.
    internal var keepsExecutedStatements: Bool {
        !rollsBackAfterStop
    }

    /// The plan the run actually uses, once the driver has been leased and asked what its session
    /// is holding.
    ///
    /// The text alone cannot see a `BEGIN` the user ran with Cmd+Enter, a `SET autocommit = 0`, a
    /// `LOCK TABLES` or an MCP client's `begin`, and every engine measured answers an app-owned
    /// `BEGIN` over one of those by committing, discarding or aborting the user's work.
    ///
    /// A session that answers `.unknown` keeps the wrap for a plain batch, but a self-managed
    /// script stops being rolled back: the transaction its text left open may predate the run, and
    /// rolling that back discards work the run never did.
    internal func joining(_ session: PluginSessionTransactionState) -> BatchTransactionPlan {
        guard session.permitsAppTransaction else { return .sessionTransaction }
        guard session == .unknown, self == .scriptTransaction else { return self }
        return .sessionTransaction
    }
}
