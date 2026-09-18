//
//  BatchCommitStatement.swift
//  TablePro
//

import Foundation

/// Whether one statement of a batch is the script's own point of no return.
///
/// A script that manages its own transaction has the same defect the app's wrap had: its `COMMIT`
/// used to run under the ordinary cancellable lease, so a Stop that landed on it either killed the
/// commit or arrived too late and reported the batch as stopped over work the server had kept.
/// ``BatchStatementRun`` routes a statement this matches through ``BatchCommitPoint`` instead, and
/// leaves the phase again afterwards so the statements after it stay stoppable.
///
/// Read from the statement's first two words rather than from the plan, because the plan cannot
/// see them: `BatchTransactionPolicy` answers `.scriptTransaction` for the whole batch as soon as
/// one statement opens a transaction, and says nothing about which statement ends it.
///
/// The ambiguity is resolved toward protecting. `END` closes a control-flow block on MySQL and
/// SQL Server and commits on PostgreSQL and SQLite, and protecting one that was not a commit costs
/// a single statement of Stop being unavailable, while missing one that was is the defect itself.
/// `END IF`, `END LOOP` and the rest are excluded because they are never a transaction's end.
internal enum BatchCommitStatement {
    private static let transactionNouns: Set<String> = ["TRANSACTION", "WORK"]

    internal static func matches(_ statement: NSString, rules: SQLLexicalRules) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "COMMIT":
            return true
        case "END":
            guard let follower = cursor.next()?.word else { return true }
            return transactionNouns.contains(follower)
        default:
            return false
        }
    }

    internal static func matches(_ statement: String, rules: SQLLexicalRules) -> Bool {
        matches(statement as NSString, rules: rules)
    }
}
