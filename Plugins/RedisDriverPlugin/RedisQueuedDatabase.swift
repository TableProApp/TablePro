//
//  RedisQueuedDatabase.swift
//  RedisDriverPlugin
//
//  Which database the session is on after a SELECT that a MULTI block queued.
//
//  A `SELECT` inside a block answers `+QUEUED` and takes effect only when `EXEC` runs. Measured on
//  Redis 8.10.1: `MULTI; SELECT 2; EXEC` then `CLIENT INFO` reports `db=2`, while `MULTI; SELECT 2;
//  DISCARD` and `MULTI; SELECT 3; RESET` both leave the session on `db=0`. So recording the index
//  at queue time is right after `EXEC` and wrong after either of the other two, and recording
//  nothing is wrong after `EXEC`.
//
//  The index has to follow the server, because it is what the `FLUSHDB` guard compares a row
//  against and what a reconnect re-selects. The queued index is therefore held aside until the
//  block resolves.
//

import Foundation

struct RedisQueuedDatabase: Equatable, Sendable {
    private(set) var pending: Int?

    mutating func queue(_ index: Int) {
        pending = index
    }

    mutating func clear() {
        pending = nil
    }

    /// The index the session moved to, when the block carrying a queued `SELECT` applied.
    ///
    /// `EXEC` answers an array for a block it ran, an error for one it refused, and a nil reply for
    /// one whose `WATCH` was broken. `DISCARD` and `RESET` end the block without running it. A
    /// nested `MULTI` is refused and leaves the block open, so only one that succeeded clears.
    mutating func resolve(command: String?, reply: RedisReply) -> Int? {
        guard let name = command?.uppercased() else { return nil }
        switch name {
        case "EXEC":
            guard case .array = reply, let index = pending else {
                pending = nil
                return nil
            }
            pending = nil
            return index
        case "DISCARD", "RESET":
            pending = nil
            return nil
        case "MULTI":
            guard !reply.isError else { return nil }
            pending = nil
            return nil
        default:
            return nil
        }
    }
}
