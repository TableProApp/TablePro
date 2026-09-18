//
//  MySQLQueryTimeout.swift
//  MySQLDriverPlugin
//
//  What enforces the query timeout on this server, and how a statement that ran past it is read.
//  Pure, so TableProTests compiles it.
//

import Foundation

/// Which statements a client-side deadline covers, matching the scope each engine's own statement
/// timeout has. Measured on MySQL 5.7.44: `max_execution_time` stops a `SELECT` and leaves
/// `SHOW TABLES ... WHERE SLEEP(5) = 0`, `CALL p()`, `DO SLEEP(5)` and `INSERT ... SELECT` alone.
/// Measured on MariaDB 10.1.48: `max_statement_time` stops all of them.
internal enum MySQLStatementDeadlineScope: Equatable, Sendable {
    case selectStatements
    case everyStatement
}

internal struct MySQLStatementDeadline: Equatable, Sendable {
    internal let seconds: Int
    internal let scope: MySQLStatementDeadlineScope

    internal func applies(to sql: String) -> Bool {
        guard seconds > 0 else { return false }
        guard scope == .selectStatements else { return true }
        return mysqlStrippedStatementBody(sql).range(
            of: #"^[\s(]*SELECT\b"#, options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

internal enum MySQLQueryTimeoutEnforcement: Equatable {
    case serverStatements([String])
    case clientDeadline(MySQLStatementDeadline)
}

/// What the version floors say this server should do with the timeout. The driver runs the flavor's
/// statements first and falls back to the deadline on the server's own refusal, so this is the
/// predicate the tests and `scripts/check-mysql-query-timeout.sh` compare a live server against
/// rather than the runtime gate: a proxy or a fork gets the banner wrong in both directions.
internal func mysqlQueryTimeoutEnforcement(
    seconds: Int,
    flavor: MySQLServerFlavor,
    banner: String?
) -> MySQLQueryTimeoutEnforcement {
    guard MySQLServerVersion.hasStatementTimeout(banner: banner, flavor: flavor) else {
        return .clientDeadline(mysqlClientDeadline(seconds: seconds, flavor: flavor))
    }
    return .serverStatements(flavor.queryTimeoutStatements(seconds: seconds))
}

internal func mysqlClientDeadline(seconds: Int, flavor: MySQLServerFlavor) -> MySQLStatementDeadline {
    MySQLStatementDeadline(seconds: seconds, scope: flavor.isMariaDB ? .everyStatement : .selectStatements)
}

/// `ERROR 1193 Unknown system variable`, which is how every server without a statement timeout
/// answers the `SET SESSION` that would install one. Any other failure is a server problem the
/// driver reports rather than a missing feature it works around.
internal let mysqlUnknownSystemVariableCode: UInt32 = 1_193

internal func mysqlRejectsStatementTimeout(code: UInt32) -> Bool {
    code == mysqlUnknownSystemVariableCode
}

internal enum MySQLStatementFailureCause: Equatable {
    case deadlineExceeded
    case outlastedSocketTimeout
    case server
}

/// Why a statement failed, which decides what the user is told and whether the statement may be run
/// again. `libmariadb` reports its own read timeout as `2013 Lost connection to server during
/// query`, the same code and text a server-side drop gets, so only the time waited separates them.
internal func mysqlStatementFailureCause(
    errno: UInt32,
    message: String,
    flavor: MySQLServerFlavor,
    deadlineExpired: Bool,
    waited: Duration,
    socketTimeoutSeconds: UInt32
) -> MySQLStatementFailureCause {
    if deadlineExpired, flavor.isInterruptedByKill(errno: errno, message: message) {
        return .deadlineExceeded
    }
    guard mysqlConnectionLossCodes.contains(errno),
          mysqlWaitCouldOutlastSocketTimeout(waited, socketTimeoutSeconds: socketTimeoutSeconds)
    else { return .server }
    return .outlastedSocketTimeout
}
