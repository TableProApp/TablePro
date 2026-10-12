//
//  RedisQueuedCommandPolicy.swift
//  RedisDriverPlugin
//
//  What an operation answers when the server queued it into an open MULTI block instead of running
//  it. Pure, so TableProTests can exercise it without loading the plugin bundle.
//

import Foundation

/// What the driver hands back for a command the server answered `+QUEUED` to.
enum RedisQueuedCommandAnswer: Equatable {
    /// The acknowledgement is the honest answer: the block is the user's to end, and `EXEC` will
    /// report every reply. The command is recorded so `EXEC`'s reply can be paired with it by
    /// position.
    case reportQueued

    /// A keyspace walk the app built for a grid. Its reply has to say the keyspace could not be
    /// read, because a one-row `QUEUED` status in the data grid reads as an empty table.
    case refuse
}

extension RedisOperation {
    /// `KEYBROWSE` and `KEYTREE` are the operations the app pages through `execute(query:)` and
    /// streams through `streamRows(query:)`, so answering them differently on the two routes would
    /// make browsing disagree with itself. Every other command is the user's own and gets the
    /// acknowledgement the server gave it.
    var queuedCommandAnswer: RedisQueuedCommandAnswer {
        switch self {
        case .keyBrowse, .keyTree: return .refuse
        case .inDatabase(_, let operation): return operation.queuedCommandAnswer
        default: return .reportQueued
        }
    }
}
