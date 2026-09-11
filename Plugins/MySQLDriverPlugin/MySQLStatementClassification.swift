//
//  MySQLStatementClassification.swift
//  MySQLDriverPlugin
//

import Foundation

internal func mysqlStatementIsReadOnly(_ query: String) -> Bool {
    let keyword = query
        .drop(while: { $0.isWhitespace })
        .prefix(while: { $0.isLetter })
        .uppercased()
    switch keyword {
    case "SELECT", "SHOW", "DESCRIBE", "DESC":
        return true
    default:
        return false
    }
}

/// A `SELECT` can still change the server, and the only caller that asks this is deciding whether a
/// statement may be run a second time after the connection dropped under it. `SELECT NEXTVAL(seq)`
/// re-run burns a second sequence value while the grid shows one, and `SELECT GET_LOCK(...)` takes
/// the lock again. Neither reports anything: the retry looks like a connection that healed itself.
///
/// The scan is deliberately crude and only ever errs toward "do not replay", which costs the user a
/// connection error where they would have got a transparent retry. It cannot see inside a stored
/// function, so a `SELECT my_function()` that writes is still replayable.
private let mysqlSideEffectingMarkers: [String] = [
    "NEXTVAL", "SETVAL", "NEXT VALUE FOR", "PREVIOUS VALUE FOR",
    "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS",
    "INTO OUTFILE", "INTO DUMPFILE", "INTO @",
    "FOR UPDATE", "FOR SHARE", "LOCK IN SHARE MODE",
    "UUID_SHORT", "MASTER_POS_WAIT", "SOURCE_POS_WAIT",
    "BENCHMARK", "SLEEP", ":=",
]

/// Whether a statement the server dropped the connection under can be run again on the session
/// that replaces it. It takes both halves: the statement has to be one that means the same thing
/// twice, and the new session has to be able to answer it the same way.
///
/// Only a session holding nothing can. Measured against MySQL 8.4.11 by killing the connection
/// and replaying: `SELECT @probe` answered `NULL` where it had answered 42, `SELECT DATABASE()`
/// answered the driver's own database over the one a `USE` had selected, and `@@SESSION.sql_mode`
/// came back as the server default over the session's `ANSI_QUOTES`. All three answered, none
/// raised, and the grid showed a value that was never true.
internal func mysqlMayReplay(_ query: String, on footprint: MySQLSessionFootprint) -> Bool {
    footprint.isClean && mysqlStatementIsSafeToReplay(query)
}

internal func mysqlStatementIsSafeToReplay(_ query: String) -> Bool {
    guard mysqlStatementIsReadOnly(query) else { return false }
    let collapsed = query
        .uppercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return !mysqlSideEffectingMarkers.contains { collapsed.contains($0) }
}
