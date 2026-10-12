//
//  MSSQLSessionTransaction.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// How the driver asks SQL Server what the session has open, and how the answer is read. No CFreeTDS
/// import, so TableProTests can exercise the decision without the plugin bundle.
///
/// `@@TRANCOUNT` is the count of open transactions, explicit and implicit alike. `XACT_STATE()`
/// answers -1 for one that can no longer be committed, which is the state a batch-aborting error
/// leaves behind, and telling the user to commit that one silently discards their work.
///
/// `SET IMPLICIT_TRANSACTIONS ON` alone is deliberately not read as a transaction. Measured on Azure
/// SQL Edge: with the option on and nothing run since, `SELECT @@TRANCOUNT, @@OPTIONS & 2` answered
/// `0 2` and asking again still answered 0, so nothing is pending and a caller's own transaction
/// commits only its own statements. The first statement after that makes `@@TRANCOUNT` 1, which is
/// what this reports.
enum MSSQLSessionTransaction {
    static let probe = "SELECT @@TRANCOUNT, XACT_STATE()"

    static func state(tranCount: String?, transactionState: String?) -> PluginSessionTransactionState {
        guard let count = tranCount.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            return .unknown
        }
        if transactionState.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) == uncommittable {
            return .abortedTransaction
        }
        return count > 0 ? .inTransaction : .idle
    }

    private static let uncommittable = -1
}
