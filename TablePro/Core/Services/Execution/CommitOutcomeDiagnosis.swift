//
//  CommitOutcomeDiagnosis.swift
//  TablePro
//

import Foundation

/// Whether a failed `COMMIT` still leaves the app able to say what became of the transaction.
///
/// A commit the server refused is an answer: the transaction is gone and the rollback that follows
/// is honest. A commit whose connection died is not an answer at all. Measured on MySQL 8.4.11: a
/// commit sitting in "Waiting for commit lock" under `FLUSH TABLES WITH READ LOCK` survived
/// `kill -9` of the client, still held its place in the process list, and committed its row once
/// the lock was released. The app's default query timeout is 60 seconds and the MySQL driver's
/// socket read timeout fires 30 seconds after that, so this is the ordinary way a blocked commit
/// ends, not a corner case.
///
/// Pure, and a text match rather than a driver question, because the error is all that crosses the
/// plugin boundary: `DatabaseError.queryFailed` carries the engine's own sentence and nothing else.
/// ``BatchCommitPoint`` asks the driver's `hasLostConnection` alongside this, so a driver that
/// knows better is believed too.
internal enum CommitOutcomeDiagnosis {
    /// Lower-cased fragments of what the engines say when the socket went before the answer did.
    /// MySQL 2006 and 2013, libpq's own four, FreeTDS, and the POSIX text Foundation produces.
    private static let connectionLossMarkers = [
        "gone away",
        "lost connection",
        "connection to the server was lost",
        "server closed the connection",
        "no connection to the server",
        "connection not open",
        "connection is closed",
        "connection was closed",
        "connection reset by peer",
        "broken pipe",
        "not connected",
        "ssl connection has been closed",
        "ssl syscall error",
        "software caused connection abort",
        "terminating connection",
        "socket is not connected",
        "network is down",
        "network is unreachable",
        "operation timed out",
        "read timed out",
    ]

    private static let posixConnectionLossCodes: Set<Int> = [
        Int(EPIPE), Int(ECONNRESET), Int(ECONNABORTED), Int(ENOTCONN),
        Int(ETIMEDOUT), Int(EHOSTUNREACH), Int(ENETDOWN), Int(ENETUNREACH), Int(ENETRESET),
    ]

    private static let urlConnectionLossCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorSecureConnectionFailed,
    ]

    internal static func isConnectionLoss(_ error: Error) -> Bool {
        if case DatabaseError.notConnected = error { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, posixConnectionLossCodes.contains(nsError.code) { return true }
        if nsError.domain == NSURLErrorDomain, urlConnectionLossCodes.contains(nsError.code) { return true }
        let message = error.localizedDescription.lowercased()
        return connectionLossMarkers.contains { message.contains($0) }
    }
}
