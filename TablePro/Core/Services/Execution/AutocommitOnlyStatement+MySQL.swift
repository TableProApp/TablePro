//
//  AutocommitOnlyStatement+MySQL.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal extension AutocommitOnlyStatement {
    /// Measured on MySQL 8.4.11 with `gtid_mode = ON` and MariaDB 11.4.13 with the binary log on,
    /// each statement run after `START TRANSACTION` and an `INSERT`. The errors are 1694, 1679,
    /// 1685, 1766, 1953, 1929, 1179, 1192 and 1568 depending on the variable; what they share is
    /// that the statement works on its own and fails inside the wrap.
    static func matchesMySQLFamily(_ statement: NSString, grammar: SQLLexicalGrammar) -> Bool {
        var cursor = SQLTokenCursor(statement, grammar: grammar)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "SET":
            return setsSomethingAutocommitOnly(&cursor)
        case "STOP":
            return replicationTargets.contains(cursor.next()?.word ?? "")
        default:
            return false
        }
    }
}

private extension AutocommitOnlyStatement {
    static let replicationTargets: Set<String> = ["SLAVE", "REPLICA", "ALL"]

    /// The characteristics of the *next* transaction, which is why MySQL answers `ERROR 1568`
    /// inside one. Only the bare `@@name` spelling means that: `SET SESSION transaction_isolation`
    /// and `SET @@SESSION.transaction_isolation` set the session variable and are allowed.
    static let nextTransactionCharacteristics: Set<String> = [
        "TRANSACTION_ISOLATION", "TRANSACTION_READ_ONLY", "TX_ISOLATION", "TX_READ_ONLY"
    ]

    static func setsSomethingAutocommitOnly(_ cursor: inout SQLTokenCursor) -> Bool {
        if cursor.peek()?.word == "TRANSACTION" { return true }
        return SQLSetAssignments.assignments(from: &cursor, readsList: true).contains(where: isAutocommitOnly)
    }

    static func isAutocommitOnly(_ assignment: SQLSetAssignment) -> Bool {
        if assignment.spelledWithAtAt, assignment.scope == .unspecified,
           nextTransactionCharacteristics.contains(assignment.name) {
            return true
        }
        guard let scope = variableScope(of: assignment.scope) else { return false }
        return MySQLAutocommitOnlyVariables.refuses(assignment.name, scope: scope)
    }

    static func variableScope(of scope: SQLSetAssignment.Scope) -> MySQLVariableScope? {
        switch scope {
        case .unspecified, .session, .local:
            return .session
        case .global, .persist:
            return .global
        case .persistOnly:
            return nil
        }
    }
}
