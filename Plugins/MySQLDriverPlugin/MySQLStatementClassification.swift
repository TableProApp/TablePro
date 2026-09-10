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

internal func mysqlStatementIsSafeToReplay(_ query: String) -> Bool {
    guard mysqlStatementIsReadOnly(query) else { return false }
    let collapsed = query
        .uppercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return !mysqlSideEffectingMarkers.contains { collapsed.contains($0) }
}
