//
//  MySQLSessionLoss.swift
//  MySQLDriverPlugin
//
//  Below MySQL 5.0 the only way to stop a statement is `KILL <id>`, which ends the session with it.
//  Pure, so TableProTests can exercise it without loading the plugin bundle.
//

import Foundation

/// What a session-ending kill left behind, and what the driver does about it before its next use.
internal struct MySQLSessionLoss: Equatable {
    enum Verdict: Equatable {
        case useConnection
        /// The kill ended a session that held nothing, so a new one loses nothing: the idle release.
        case reacquire
        /// The kill ended a session that held something. Said once, with what it held.
        case report(reason: String)
        /// Already said. Only the app's reconnect restores the startup SQL, the database and the timeout.
        case lost
    }

    private struct Pending: Equatable {
        let connection: ObjectIdentifier
        let reason: String?
    }

    private var pending: Pending?
    private(set) var isLost = false

    /// Taken before the kill goes out, because the kill lands on another queue and the next statement
    /// must never find the session ended with nothing noted.
    mutating func noteKill(on connection: ObjectIdentifier, holding reason: String?) {
        pending = Pending(connection: connection, reason: reason)
    }

    /// A kill the driver approved is judged by the note taken just before it: a statement that
    /// arrived after the kill was observed before the connection refused to send it, so what the
    /// session holds now overstates it. Any other kill, such as the cleanup of a statement the socket
    /// timeout gave up on, is judged by what the session holds now, because a note left by an
    /// approved kill that never went out says nothing about it.
    mutating func verdict(
        for connection: ObjectIdentifier?,
        sessionEndedByKill: Bool,
        killWasApproved: Bool,
        holding current: String?
    ) -> Verdict {
        guard !isLost else { return .lost }
        guard let connection, sessionEndedByKill else { return .useConnection }
        let noted = pending.flatMap { killWasApproved && $0.connection == connection ? $0 : nil }
        pending = nil
        guard let reason = noted.map(\.reason) ?? current else { return .reacquire }
        isLost = true
        return .report(reason: reason)
    }

    mutating func reset() {
        self = MySQLSessionLoss()
    }
}
