//
//  RedisTransactionOutcome.swift
//  RedisDriverPlugin
//
//  What EXEC's reply says about the block it just applied.
//
//  EXEC answers one element per queued command and puts a command's failure in that element, so a
//  caller that reads only the top level reports success for a block half of which the server
//  refused. Measured on Redis 8.10.1: `MULTI; GET s; LPUSH s x; SET t 1; DEL nokey; INCR s; EXEC`
//  answers an array of five holding `-WRONGTYPE` and `-ERR value is not an integer`, `GET t` then
//  answers 1, and nothing was rolled back. The grid-save shape is the same: a `RENAME` of a missing
//  key followed by a `SET` answered `+OK` at the top level while the `SET` was applied.
//
//  A queue-time refusal is a different reply and needs no pairing: it arrives as a top-level
//  `-EXECABORT` and applies nothing, which `throwIfError` already raises. Measured for an ACL user
//  without `+expire` (`-NOPERM` then `-EXECABORT`, `EXISTS b` 0) and under `maxmemory 1` (`-OOM`
//  then `-EXECABORT`, the renamed key untouched).
//

import Foundation
import TableProPluginKit

/// One command the block ran and the server refused, labelled with the command the app queued at
/// that position.
struct RedisFailedCommand: Equatable, Sendable {
    let label: String
    let message: String
}

struct RedisTransactionError: Error, Equatable {
    let failed: [RedisFailedCommand]
}

extension RedisTransactionError: PluginDriverError {
    var pluginErrorMessage: String {
        if failed.count == 1, let only = failed.first {
            return String(
                format: String(localized: "%1$@ failed inside the Redis transaction: %2$@"),
                only.label, only.message
            )
        }
        return String(
            format: String(localized: "%1$lld commands failed inside the Redis transaction: %2$@"),
            failed.count,
            failed.map { "\($0.label): \($0.message)" }.joined(separator: ", ")
        )
    }

    var pluginErrorDetail: String? {
        String(localized: "EXEC ran the other commands in the block, and Redis cannot roll them back.")
    }
}

enum RedisTransactionOutcome {
    /// Pairs EXEC's reply array with the commands queued into the block, in order.
    ///
    /// A reply that is not an array is a block that never ran: `-EXECABORT` for a queue-time
    /// refusal, `-ERR EXEC without MULTI` for one `RESET` already ended, and a nil reply for one
    /// whose `WATCH` was broken. None of them applied anything, so none of them names a failure
    /// here.
    static func failures(inExecReply reply: RedisReply, queuedCommands: [String]) -> [RedisFailedCommand] {
        guard case .array(let elements) = reply else { return [] }
        return elements.enumerated().compactMap { index, element in
            guard let message = element.errorMessage else { return nil }
            return RedisFailedCommand(label: label(at: index, in: queuedCommands), message: message)
        }
    }

    /// The block can hold commands the driver never saw queued, because a user is free to type
    /// their own `MULTI` on the same session, so a position with no recorded command is named by
    /// its position rather than dropped.
    private static func label(at index: Int, in queuedCommands: [String]) -> String {
        guard index < queuedCommands.count, !queuedCommands[index].isEmpty else {
            return String(format: String(localized: "Command %lld"), index + 1)
        }
        return queuedCommands[index]
    }
}
